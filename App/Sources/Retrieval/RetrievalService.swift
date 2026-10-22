import Foundation

/// Glue between the question, the index and the ranker.
///
/// Two passes: the OR expression first; if it returns almost nothing (very
/// specific questions), a stricter AND pass runs. Results are ranked by
/// `Ranker` (RRF), de-duplicated, then trimmed to `passages` entries.
final class RetrievalService {

    private let store: CorpusStore
    private let queryBuilder: QueryBuilder
    private let ranker: Ranker

    var candidatePool: Int = 40
    var passagesPerAnswer: Int = 5

    init(store: CorpusStore,
         queryBuilder: QueryBuilder = QueryBuilder(),
         ranker: Ranker = Ranker()) {
        self.store = store
        self.queryBuilder = queryBuilder
        self.ranker = ranker
    }

    func retrieve(question: String) throws -> RetrievalResult {
        let started = DispatchTime.now()
        let expression = queryBuilder.build(question)
        guard !expression.isEmpty else {
            return .empty
        }

        var candidates = try store.search(expression: expression.primary, limit: candidatePool)
        var usedStrict = false

        if candidates.count < 3, !expression.strict.isEmpty {
            let strict = try store.search(expression: expression.strict, limit: candidatePool)
            if strict.count > candidates.count {
                candidates = strict
            }
            usedStrict = true
        }

        let ranked = ranker.rank(candidates, terms: expression.terms, phrases: expression.phrases)
        let deduped = ranker.dedupe(ranked)
        let selected = Array(deduped.prefix(passagesPerAnswer))

        var citations: [Citation] = []
        for (offset, passage) in selected.enumerated() {
            citations.append(Citation(index: offset + 1,
                                      title: passage.title,
                                      url: passage.url,
                                      passageID: passage.id))
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        return RetrievalResult(question: question,
                               passages: selected,
                               citations: citations,
                               candidatesConsidered: candidates.count,
                               elapsedMilliseconds: elapsed,
                               usedStrictFallback: usedStrict)
    }

    /// Used by Diagnostics: a handful of representative queries with timings.
    func diagnose() -> [(String, Int, Int)] {
        let probes = ["why does antibiotic resistance spread",
                      "how does a lithium-ion battery work",
                      "what is entropy"]
        return probes.map { probe in
            let started = DispatchTime.now()
            let result = (try? retrieve(question: probe)) ?? .empty
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            return (probe, result.candidatesConsidered, elapsed)
        }
    }
}
