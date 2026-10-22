#!/usr/bin/env python3
"""Offline retrieval evaluation for the bundled corpus.

This mirrors, in Python, exactly what the app does in Swift:
  1. QueryBuilder  -> FTS5 MATCH expression (OR of quoted content terms)
  2. SQLite        -> top-N candidates ranked by bm25()
  3. Ranker        -> blend of normalised bm25, IDF-weighted term coverage,
                      title agreement and phrase hits

It reports hit@1/3/5 and MRR for both the raw bm25 pass and the blended pass, so
the contribution of the reranker is visible instead of asserted.

The gold set lives in Scripts/eval/questions.jsonl:
    {"q": "...", "gold": ["Article title", ...], "kind": "explain|compare|recall"}

Usage:
    python3 Scripts/eval_retrieval.py --db App/Resources/corpus.sqlite \
        --questions Scripts/eval/questions.jsonl --k 5 --json out.json
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sqlite3
import statistics
import unicodedata

STOPWORDS = set("""a about above after again against all am an and any are as at be because been before
being below between both but by can cannot could did do does doing down during each few for from further
had has have having he her here hers herself him himself his how i if in into is it its itself just me more
most my myself no nor not now of off on once only or other our ours ourselves out over own same she should
so some such than that the their theirs them themselves then there these they this those through to too
under until up very was we were what when where which while who whom why will with would you your yours
yourself yourselves please tell explain describe give want need know mean means meaning difference compare""".split())

INTENT = set("why how cause causes effect effects risk risks versus vs better worse faster slower cheaper more less tradeoff tradeoffs".split())


def fold(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return text.casefold()


def raw_terms(text: str) -> list[str]:
    text = fold(text).replace("'s", " ").replace("'", "")
    return [t for t in re.split(r"[^a-z0-9+#]+", text) if t]


def stem(word: str) -> str:
    """Mirror of TextNormalizer.stem - conservative suffix rules only.

    An aggressive stemmer here would silently diverge from the Swift
    implementation and from SQLite's non-stemming unicode61 tokenizer.
    """
    n = len(word)
    if n <= 3:
        return word
    if word.endswith("ies") and n >= 5:
        return word[:-3] + "y"
    if word.endswith("sses"):
        return word[:-2]
    for sibilant in ("ches", "shes", "xes", "zes", "ses"):
        if word.endswith(sibilant):
            return word[:-2]
    if word.endswith("s") and n >= 4 and not word.endswith(("ss", "us", "is")):
        return word[:-1]
    if word.endswith("ing") and n >= 6:
        return word[:-3]
    if word.endswith("ed") and n >= 5:
        return word[:-2]
    return word


def query_terms(question: str, cap: int = 12) -> list[str]:
    seen, content, intent = set(), [], []
    for term in (stem(t) for t in raw_terms(question)):
        if len(term) <= 1 or term in seen:
            continue
        seen.add(term)
        if term in STOPWORDS:
            continue
        (intent if term in INTENT else content).append(term)
    return (content + intent)[:cap]


def phrases(question: str, limit: int = 3) -> list[str]:
    words = raw_terms(question)
    lead = {"what", "why", "how", "when", "where", "which", "who", "does", "do", "is", "are", "can",
            "explain", "describe", "compare", "tell"}
    trail = {"mean", "means", "meaning", "work", "works", "happen", "happens"}
    while words and words[0] in lead:
        words.pop(0)
    while words and words[-1] in trail:
        words.pop()
    out = []
    for a, b in zip(words, words[1:]):
        if a not in STOPWORDS and b not in STOPWORDS:
            out.append(f"{a} {b}")
        if len(out) >= limit:
            break
    return out


def fts_expression(terms: list[str], prefix_min: int = 4) -> str:
    """Quoted FTS5 expression with prefix variants, mirroring QueryBuilder.swift."""
    variants: list[str] = []
    seen = set()
    for term in terms:
        for candidate in (term, stem(term)):
            if len(candidate) > 1 and candidate not in seen:
                seen.add(candidate)
                variants.append(candidate)
    return " OR ".join(f'"{v}"*' if len(v) >= prefix_min else f'"{v}"' for v in variants)


def search(db: sqlite3.Connection, expr: str, limit: int) -> list[dict]:
    if not expr:
        return []
    rows = db.execute(
        """SELECT c.id, c.doc_id, d.title, d.url, c.ordinal, c.text, bm25(chunks_fts) AS s
           FROM chunks_fts
           JOIN chunks c ON c.id = chunks_fts.rowid
           JOIN docs  d ON d.id = c.doc_id
           WHERE chunks_fts MATCH ?
           ORDER BY s
           LIMIT ?""",
        (expr, limit),
    ).fetchall()
    return [
        {"id": r[0], "doc_id": r[1], "title": r[2], "url": r[3], "ordinal": r[4], "text": r[5], "bm25": r[6]}
        for r in rows
    ]


def rank(cands: list[dict], terms: list[str], phrase_list: list[str], k: float = 60.0) -> list[dict]:
    """Mirror of Ranker.swift: reciprocal rank fusion of bm25, coverage, title."""
    if not cands or not terms:
        return cands
    n = len(cands)
    df = {t: sum(1 for c in cands if t in fold(c["text"])) for t in terms}

    coverage = []
    title_hits = []
    for c in cands:
        text = fold(c["text"])
        title = fold(c["title"])
        covered = weight = 0.0
        for t in terms:
            idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            weight += idf
            if t in text:
                covered += idf
                covered += idf * 0.1 * (min(text.count(t), 3) - 1)
        value = min(1.0, covered / weight) if weight else 0.0
        if phrase_list:
            value += 0.25 * (sum(1 for p in phrase_list if p in text) / len(phrase_list))
        coverage.append(value)
        title_hits.append(sum(1 for t in terms if t in title) / len(terms))

    by_bm25 = sorted(range(n), key=lambda i: (cands[i]["bm25"], cands[i]["id"]))
    by_cov = sorted(range(n), key=lambda i: (-coverage[i], cands[i]["id"]))
    by_title = sorted(range(n), key=lambda i: (-title_hits[i], cands[i]["id"]))
    pos_bm25 = {idx: r for r, idx in enumerate(by_bm25)}
    pos_cov = {idx: r for r, idx in enumerate(by_cov)}
    pos_title = {idx: r for r, idx in enumerate(by_title)}

    for idx, c in enumerate(cands):
        c["coverage"] = coverage[idx]
        c["score"] = (1.0 / (k + pos_bm25[idx])
                      + 1.0 / (k + pos_cov[idx])
                      + 1.0 / (k + pos_title[idx]))
    return sorted(cands, key=lambda c: (-c["score"], c["id"]))


def dedupe_titles(cands: list[dict], k: int) -> list[str]:
    out: list[str] = []
    for c in cands:
        if c["title"] not in out:
            out.append(c["title"])
        if len(out) >= k:
            break
    return out


def maybe_resolve_gold(conn: sqlite3.Connection, questions: list[dict]) -> tuple[list[dict], list[str]]:
    """Map gold labels onto the titles that actually exist in the corpus.

    Wikipedia redirects rename articles ("Antibiotic resistance" ->
    "Antimicrobial resistance"), so a literal string comparison understates
    retrieval quality. We resolve each gold label to an existing corpus title by
    exact match, then token-Jaccard similarity. Unresolvable labels are reported
    and their questions are dropped from the metrics rather than silently scored
    as misses.
    """
    titles = [r[0] for r in conn.execute("SELECT DISTINCT title FROM docs")]
    by_fold = {fold(t): t for t in titles}
    token_sets = {t: set(raw_terms(t)) for t in titles}

    resolved, dropped = [], []
    for item in questions:
        golds, unresolved = [], []
        for gold in item["gold"]:
            key = fold(gold)
            if key in by_fold:
                golds.append(by_fold[key])
                continue
            best, best_score = None, 0.0
            target = set(raw_terms(gold))
            for title, tokens in token_sets.items():
                if not target or not tokens:
                    continue
                score = len(target & tokens) / len(target | tokens)
                if score > best_score:
                    best, best_score = title, score
            if best and best_score >= 0.8:
                golds.append(best)
            else:
                unresolved.append(gold)
        if unresolved:
            dropped.append(f"{item['q'][:60]} -> unresolved {unresolved}")
            continue
        resolved.append({**item, "gold": golds, "gold_raw": item["gold"]})
    return resolved, dropped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="App/Resources/corpus.sqlite")
    ap.add_argument("--questions", default="Scripts/eval/questions.jsonl")
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--candidates", type=int, default=40)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    questions = [json.loads(l) for l in pathlib.Path(args.questions).read_text().splitlines() if l.strip()]
    questions, unresolved = maybe_resolve_gold(db, questions)
    if unresolved:
        print(f"dropped {len(unresolved)} question(s) whose gold article is not bundled:")
        for line in unresolved:
            print(f"  - {line}")

    rows = []
    for item in questions:
        terms = query_terms(item["q"])
        expr = fts_expression(terms)
        cands = search(db, expr, args.candidates)
        blended = rank([dict(c) for c in cands], terms, phrases(item["q"]))
        raw_titles = dedupe_titles(cands, args.k)
        blend_titles = dedupe_titles(blended, args.k)
        gold = {g.casefold() for g in item["gold"]}

        def hit_rank(titles: list[str]) -> int:
            for i, title in enumerate(titles, 1):
                if title.casefold() in gold:
                    return i
            return 0

        rows.append({
            "q": item["q"],
            "kind": item.get("kind", "recall"),
            "gold": item["gold"],
            "terms": terms,
            "candidates": len(cands),
            "raw_rank": hit_rank(raw_titles),
            "blend_rank": hit_rank(blend_titles),
            "blend_top": blend_titles[:3],
        })

    def summarize(key: str) -> dict:
        ranks = [r[key] for r in rows]
        n = len(ranks)
        within = lambda k: sum(1 for r in ranks if 1 <= r <= k) / n  # noqa: E731
        mrr = sum(1.0 / r for r in ranks if r) / n
        return {"n": n, "hit@1": round(within(1), 3), "hit@3": round(within(3), 3),
                "hit@5": round(within(5), 3), "mrr": round(mrr, 3),
                "misses": sum(1 for r in ranks if r == 0)}

    by_kind: dict[str, list[dict]] = {}
    for row in rows:
        by_kind.setdefault(row["kind"], []).append(row)

    report = {
        "db": args.db,
        "questions": len(rows),
        "k": args.k,
        "raw_bm25": summarize("raw_rank"),
        "blended": summarize("blend_rank"),
        "by_kind": {
            kind: {
                "n": len(items),
                "raw_hit@3": round(sum(1 for i in items if 1 <= i["raw_rank"] <= 3) / len(items), 3),
                "blend_hit@3": round(sum(1 for i in items if 1 <= i["blend_rank"] <= 3) / len(items), 3),
            }
            for kind, items in by_kind.items()
        },
        "median_candidates": statistics.median([r["candidates"] for r in rows]),
        "rows": rows,
    }

    print(f"questions={report['questions']} k={args.k}")
    for key in ("raw_bm25", "blended"):
        s = report[key]
        print(f"{key:9s} hit@1={s['hit@1']:.3f} hit@3={s['hit@3']:.3f} hit@5={s['hit@5']:.3f} mrr={s['mrr']:.3f} misses={s['misses']}")
    for kind, s in report["by_kind"].items():
        print(f"  {kind:8s} n={s['n']:2d} hit@3 raw={s['raw_hit@3']:.2f} blend={s['blend_hit@3']:.2f}")
    if report["blended"]["misses"]:
        print("misses:")
        for row in rows:
            if row["blend_rank"] == 0:
                print(f"  - {row['q'][:70]!r} gold={row['gold']} top={row['blend_top']}")

    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
        print(f"json -> {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
