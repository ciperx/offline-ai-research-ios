#!/usr/bin/env python3
"""Build the bundled SQLite FTS5 index from Corpus/raw/wiki.jsonl.

Output: App/Resources/corpus.sqlite  (read-only at runtime, copied into the app bundle)

Schema
------
  meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)
  docs(id INTEGER PRIMARY KEY, doc_key TEXT UNIQUE, title TEXT, url TEXT,
       license TEXT, revision INTEGER, char_len INTEGER, text TEXT)
  chunks(id INTEGER PRIMARY KEY, doc_id INTEGER REFERENCES docs(id),
         ordinal INTEGER, section TEXT, char_len INTEGER, text TEXT)
  chunks_fts  -- FTS5(text, title, section) with rowid = chunks.id
  chunks_fts_idx is implicit; bm25(chunks_fts) gives the ranking used by the app.

Chunking is paragraph-aware: paragraphs are packed up to ~TARGET_CHARS, a chunk
never crosses a section heading, and chunks overlap by one trailing sentence so a
fact split across a boundary is still retrievable.

Usage:
    python3 Scripts/build_index.py \
        --input Corpus/raw/wiki.jsonl \
        --output App/Resources/corpus.sqlite
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sqlite3
import sys
import time

BUILDER_VERSION = "1.1.0"
TARGET_CHARS = 900
MAX_CHARS = 1400
MIN_CHARS = 120
OVERLAP_SENTENCES = 1

HEADING = re.compile(r"^=+\s*(.*?)\s*=+$")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\"'])")

SCHEMA = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
PRAGMA page_size = 4096;

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE docs (
    id        INTEGER PRIMARY KEY,
    doc_key   TEXT UNIQUE NOT NULL,
    title     TEXT NOT NULL,
    url       TEXT,
    license   TEXT,
    revision  INTEGER,
    char_len  INTEGER NOT NULL
);

CREATE TABLE chunks (
    id       INTEGER PRIMARY KEY,
    doc_id   INTEGER NOT NULL REFERENCES docs(id),
    ordinal  INTEGER NOT NULL,
    section  TEXT NOT NULL DEFAULT '',
    title    TEXT NOT NULL,
    char_len INTEGER NOT NULL,
    text     TEXT NOT NULL
);

-- External-content FTS: the index does not store a second copy of the text, it
-- reads rows from `chunks` by rowid. Roughly halves the file size.
CREATE VIRTUAL TABLE chunks_fts USING fts5(
    title,
    text,
    section,
    content = 'chunks',
    content_rowid = 'id',
    tokenize = 'unicode61 remove_diacritics 2'
);

CREATE INDEX chunks_doc ON chunks(doc_id, ordinal);
"""


def split_sections(text: str) -> list[tuple[str, str]]:
    """Return [(section_title, body)] preserving order. Lead section title ''."""
    sections: list[tuple[str, str]] = []
    current_title = ""
    buffer: list[str] = []

    def flush() -> None:
        body = "\n".join(buffer).strip()
        if body:
            sections.append((current_title, body))

    for line in text.splitlines():
        match = HEADING.match(line.strip())
        if match:
            flush()
            buffer = []
            current_title = match.group(1)
            continue
        buffer.append(line)
    flush()
    return sections


def paragraph_candidates(body: str) -> list[str]:
    """Wikipedia plaintext separates paragraphs with a single blank line."""
    parts = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
    out: list[str] = []
    for part in parts:
        part = re.sub(r"\s+", " ", part)
        if len(part) <= MAX_CHARS:
            out.append(part)
            continue
        # Oversized paragraph: split on sentence boundaries, packing to TARGET.
        sentences = SENTENCE_SPLIT.split(part)
        buf = ""
        for sentence in sentences:
            if len(buf) + len(sentence) + 1 <= TARGET_CHARS:
                buf = f"{buf} {sentence}".strip()
            else:
                if buf:
                    out.append(buf)
                buf = sentence if len(sentence) <= MAX_CHARS else sentence[:MAX_CHARS]
        if buf:
            out.append(buf)
    return out


def chunk_text(body: str) -> list[str]:
    chunks: list[str] = []
    buf = ""
    for paragraph in paragraph_candidates(body):
        if not buf:
            buf = paragraph
            continue
        if len(buf) + len(paragraph) + 2 <= TARGET_CHARS:
            buf = f"{buf}\n\n{paragraph}"
        else:
            chunks.append(buf)
            # One-sentence overlap so boundary-spanning facts stay retrievable.
            tail = SENTENCE_SPLIT.split(buf)
            overlap = " ".join(tail[-OVERLAP_SENTENCES:]) if OVERLAP_SENTENCES else ""
            buf = f"{overlap}\n\n{paragraph}".strip() if len(overlap) < 400 else paragraph
    if buf:
        chunks.append(buf)
    return [c for c in (c.strip() for c in chunks) if len(c) >= MIN_CHARS]


def main() -> int:
    global TARGET_CHARS
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="Corpus/raw/wiki.jsonl")
    ap.add_argument("--output", default="App/Resources/corpus.sqlite")
    ap.add_argument("--target-chars", type=int, default=TARGET_CHARS)
    ap.add_argument("--max-docs", type=int, default=0)
    args = ap.parse_args()

    TARGET_CHARS = args.target_chars

    src = pathlib.Path(args.input)
    if not src.exists():
        print(f"missing input {src}; run Scripts/fetch_corpus.py first", file=sys.stderr)
        return 2

    records = []
    for line in src.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if args.max_docs:
        records = records[: args.max_docs]
    if not records:
        print("no records", file=sys.stderr)
        return 2

    # Deduplicate by doc_key: the fetch step can append the same article twice
    # (retry after a partial write), and docs.doc_key is UNIQUE.
    seen_keys = set()
    deduped = []
    for rec in records:
        key = rec.get("key") or rec.get("title") or ""
        if not key:
            continue
        if key in seen_keys:
            continue
        seen_keys.add(key)
        deduped.append(rec)
    dropped = len(records) - len(deduped)
    records = deduped
    if dropped:
        print(f"deduped {dropped} duplicate doc_key rows", file=sys.stderr)

    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    con = sqlite3.connect(out)
    con.executescript(SCHEMA)

    total_chunks = 0
    for doc_id, rec in enumerate(records, 1):
        text = rec.get("text", "")
        title = rec.get("title", "")
        con.execute(
            "INSERT INTO docs(id, doc_key, title, url, license, revision, char_len) "
            "VALUES (?,?,?,?,?,?,?)",
            (doc_id, rec.get("key", title or f"doc-{doc_id}"), title,
             rec.get("url"), rec.get("license"), rec.get("revision"), len(text)),
        )
        ordinal = 0
        for section, body in split_sections(text):
            for chunk in chunk_text(body):
                ordinal += 1
                cur = con.execute(
                    "INSERT INTO chunks(doc_id, ordinal, section, title, char_len, text) "
                    "VALUES (?,?,?,?,?,?)",
                    (doc_id, ordinal, section[:120], title, len(chunk), chunk),
                )
                con.execute(
                    "INSERT INTO chunks_fts(rowid, title, text, section) VALUES (?,?,?,?)",
                    (cur.lastrowid, title, chunk, section[:120]),
                )
                total_chunks += 1

    source_sha = hashlib.sha256(src.read_bytes()).hexdigest()
    meta = {
        "schema_version": "1",
        "builder_version": BUILDER_VERSION,
        "built_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source_file": src.as_posix(),
        "source_sha256": source_sha,
        "documents": str(len(records)),
        "chunks": str(total_chunks),
        "target_chars": str(TARGET_CHARS),
        "tokenizer": "unicode61 remove_diacritics 2",
        "license": "CC-BY-SA-4.0 (see ATTRIBUTION.md)",
        "ranking": "bm25(chunks_fts) then Ranker.swift blend",
    }
    con.executemany("INSERT INTO meta(key, value) VALUES (?,?)", meta.items())
    con.commit()

    integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
    fts_rows = con.execute("SELECT count(*) FROM chunks_fts").fetchone()[0]
    con.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('optimize')")
    con.commit()
    con.close()

    size = out.stat().st_size
    print(f"docs={len(records)} chunks={total_chunks} fts_rows={fts_rows} size={size/1e6:.1f} MB")
    print(f"integrity_check={integrity}")
    print(f"source_sha256={source_sha}")
    print(f"written -> {out}")
    return 0 if integrity == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
