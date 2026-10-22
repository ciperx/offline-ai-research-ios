# Offline AI Research (iOS)

A fully offline, on-device research assistant for iOS: you ask a question, the app
retrieves passages from a local corpus and answers **with citations** — no network,
no telemetry, no API keys.

Built as a submission for the poidh bounty *"Build the BEST Offline AI Research App
for iOS"* (Base, bounty 1405), which follows Vitalik's original Android brief:
fully offline, small local model, cited answers, no cloud dependency.

![No network](https://img.shields.io/badge/network-none-brightgreen)

## What works today

| Component | Status |
|---|---|
| SQLite FTS5 corpus + BM25 ranking | working (`App/Resources/corpus.sqlite`, 369 docs / 17,846 chunks) |
| Hybrid ranker (BM25 + lexical overlap, RRF fusion) | working (`Core/Sources/OfflineResearchCore/Ranker.swift`) |
| Extractive answer composer with inline citations | working, used when no GGUF is installed |
| llama.cpp generative engine (GGUF, Metal/CPU) | implemented (`LlamaEngine.swift`), needs a model file |
| Network kill switch (`URLProtocol` that refuses every request) | working (`OfflineGuard.swift`) |
| SwiftUI app shell (question → answer → sources) | working (`App/Sources/App/`) |
| Corpus tooling (fetch Wikipedia → build index) | working (`Scripts/`) |

## Measured retrieval quality

`Scripts/eval_retrieval.py` on 51 held-out questions against the bundled corpus:

```
hit@1  0.431
hit@3  0.549
hit@5  0.588
MRR    0.495
```

These are raw-BM25 baseline numbers on short, out-of-corpus-style questions
("Why does time dilate at high speed?"). They are published as-is, including the
failures: vague conceptual questions are the weak spot, and the fix is a denser
corpus plus query expansion, not a bigger model.

## Architecture

```
Question
   │
   ├─ QueryBuilder ──────────► FTS5 MATCH expression (OR, then strict AND fallback)
   │                              │
   │                          CorpusStore (SQLite, bundled, read-only)
   │                              │
   │                          Ranker: BM25 + lexical overlap, RRF fusion, dedupe
   │                              │
   │                    ┌─────────┴──────────┐
   │            GGUF installed          no model
   │                    │                   │
   │             LlamaEngine          ExtractiveComposer
   │          (llama.cpp, Metal)      (sentence selection)
   │                    └─────────┬──────────┘
   └──────────────────────────────► Answer + [n] citations → Passage text
```

* `Core/` — platform-independent SwiftPM package: normalisation, query building,
  ranking, prompt building, extractive composition, model catalog. Testable on
  Linux CI without Xcode.
* `App/` — iOS app: retrieval service, GGUF engine, offline guard, SwiftUI views.
* `Corpus/` — raw JSONL + manifest used to build the SQLite index.
* `Scripts/` — corpus fetcher, index builder, retrieval evaluator (Python).

## Offline guarantee

`OfflineGuard` installs a `URLProtocol` that intercepts every request in the app's
session and fails it, recording the attempted host for the diagnostics screen.
`EngineFactory` refuses to load a model that is not inside the app container. The
app never ships an HTTP client for inference and has no analytics dependency.

## Build

```bash
# 1. corpus → index (Python 3, no third-party deps)
python3 Scripts/fetch_corpus.py        # writes Corpus/raw/wiki.jsonl
python3 Scripts/build_index.py         # writes App/Resources/corpus.sqlite

# 2. evaluate retrieval
python3 Scripts/eval_retrieval.py --questions Scripts/eval/questions.jsonl

# 3. core package (works on Linux/macOS)
swift test --package-path Core

# 4. iOS app
brew install xcodegen
cd App && xcodegen generate && open OfflineResearch.xcodeproj
```

An optional GGUF model (Qwen2.5-1.5B-Instruct Q4_K_M, ~1 GB) can be dropped into
the app's Documents directory; without it the app answers extractively.

## Roadmap

1. Query expansion from corpus co-occurrence to lift `hit@5` on conceptual questions.
2. Streaming token output in the UI (engine already emits `EngineEvent` deltas).
3. On-device index update: add a document by sharing a text file into the app.
4. Multi-lingual normaliser (currently English-centric stemming).

## License

MIT — see `LICENSE`.
