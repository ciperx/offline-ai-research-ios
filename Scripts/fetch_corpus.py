#!/usr/bin/env python3
"""Fetch a pinned, license-clean research corpus from Wikipedia (CC BY-SA 4.0).

Build-time only. The shipped iOS app performs zero network I/O; this script runs
on the developer's machine to (re)generate `Corpus/raw/wiki.jsonl`, which then
becomes the bundled SQLite FTS5 index via `Scripts/build_index.py`.

Design notes:
  * one article per request -- the multi-title extracts endpoint rate limits hard
  * resumable -- titles already present in the output file are skipped
  * provenance -- every record keeps its canonical URL and revision id
  * the manifest records a SHA-256 of the exact JSONL that produced the index

Usage:
    python3 Scripts/fetch_corpus.py --topics Corpus/topics.txt --out Corpus/raw/wiki.jsonl
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "OfflineResearchCorpusBuilder/1.0 (https://github.com/ciperx/ios-offline-research; build-time only)"


def _fetch(url: str, retries: int = 8) -> bytes:
    last: object = "unknown"
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}"
            retry_after = exc.headers.get("Retry-After") if exc.headers else None
            if exc.code == 429:
                wait = float(retry_after) if retry_after and retry_after.isdigit() else 45.0 + 15.0 * attempt
                print(f"    429; sleeping {wait:.0f}s", flush=True)
                time.sleep(wait)
                continue
            time.sleep(3.0 * (attempt + 1))
        except Exception as exc:  # noqa: BLE001 - build script: retry, then fail loud
            last = repr(exc)
            time.sleep(3.0 * (attempt + 1))
    raise RuntimeError(f"request failed after {retries} attempts: {last}")


def api_get(title: str, lang: str) -> dict:
    params = {
        "action": "query",
        "format": "json",
        "formatversion": "2",
        "prop": "extracts|info",
        "inprop": "url",
        "explaintext": "1",
        "exsectionformat": "plain",
        "redirects": "1",
        "titles": title,
    }
    url = f"https://{lang}.wikipedia.org/w/api.php?" + urllib.parse.urlencode(params)
    return json.loads(_fetch(url).decode("utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topics", default="Corpus/topics.txt")
    ap.add_argument("--out", default="Corpus/raw/wiki.jsonl")
    ap.add_argument("--lang", default="en")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--min-chars", type=int, default=1200)
    ap.add_argument("--delay", type=float, default=0.45)
    args = ap.parse_args()

    topics = [
        line.strip()
        for line in pathlib.Path(args.topics).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if args.limit:
        topics = topics[: args.limit]
    if not topics:
        print("no topics", file=sys.stderr)
        return 1

    out_path = pathlib.Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    have: set[str] = set()
    if out_path.exists():
        for line in out_path.read_text(encoding="utf-8").splitlines():
            try:
                have.add(json.loads(line)["key"].lower())
            except Exception:  # noqa: BLE001 - tolerate a half-written last line
                continue

    added = skipped = 0
    with out_path.open("a", encoding="utf-8") as fh:
        for idx, topic in enumerate(topics, 1):
            if topic.lower() in have:
                continue
            try:
                data = api_get(topic, args.lang)
            except Exception as exc:  # noqa: BLE001 - keep going, summarise at the end
                print(f"[{idx}/{len(topics)}] FAIL {topic}: {exc}", flush=True)
                skipped += 1
                continue
            pages = data.get("query", {}).get("pages", [])
            page = pages[0] if pages else {}
            text = (page.get("extract") or "").strip()
            if not page or "missing" in page or page.get("invalid") or len(text) < args.min_chars:
                skipped += 1
                print(f"[{idx}/{len(topics)}] skip {topic} ({len(text)} chars)", flush=True)
                continue
            rec = {
                "key": page["title"].strip(),
                "title": page["title"].strip(),
                "url": page.get("fullurl", ""),
                "lang": args.lang,
                "license": "CC-BY-SA-4.0",
                "revision": page.get("lastrevid"),
                "text": text,
            }
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            fh.flush()
            have.add(rec["key"].lower())
            added += 1
            print(f"[{idx}/{len(topics)}] +{rec['key']} ({len(text)} chars)", flush=True)
            time.sleep(args.delay)

    digest = hashlib.sha256(out_path.read_bytes()).hexdigest()
    docs = sum(1 for _ in out_path.open("r", encoding="utf-8"))
    manifest_path = pathlib.Path("Corpus/manifest.json")
    manifest: dict = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            manifest = {}
    manifest.setdefault("schema", 1)
    manifest["wikipedia"] = {
        "source": "English Wikipedia plaintext extracts (action=query&prop=extracts&explaintext)",
        "license": "CC-BY-SA-4.0",
        "attribution": "ATTRIBUTION.md -- each record keeps its canonical URL and revision id",
        "lang": args.lang,
        "documents": docs,
        "sha256": digest,
        "file": out_path.as_posix(),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"done: +{added} added, {skipped} skipped, {docs} docs total, sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
