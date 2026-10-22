import Foundation

/// Fusion of three cheap lexical signals by Reciprocal Rank Fusion:
///
///   1. SQLite `bm25()` order      — already a strong lexical ranker
///   2. IDF-weighted term coverage — rewards passages that cover *all* rare terms
///   3. Title agreement            — separates "is about X" from "mentions X"
///
/// Score fusion (normalising bm25 and adding weighted scores) was measurably
/// worse than raw bm25 on the bundled corpus; RRF is scale-free and needs no
/// per-corpus tuning. Numbers and the experiment: docs/BENCHMARKS.md.
///
/// Deterministic and dependency-free, so it is unit-tested on Linux.
public struct Ranker {

    /// RRF smoothing constant. 60 is the value from the original TREC work; the
    /// result is not sensitive to it on a corpus of this size.
    public var k: Double
    public var bm25Weight: Double
    public var coverageWeight: Double
    public var titleWeight: Double

    public init(k: Double = 60,
                bm25Weight: Double = 1.0,
                coverageWeight: Double = 1.0,
                titleWeight: Double = 1.0) {
        self.k = k
        self.bm25Weight = bm25Weight
        self.coverageWeight = coverageWeight
        self.titleWeight = titleWeight
    }

    public func rank(_ passages: [Passage], terms: [String], phrases: [String]) -> [Passage] {
        guard !passages.isEmpty, !terms.isEmpty else { return passages }

        let n = Double(passages.count)
        var documentFrequency: [String: Int] = [:]
        for term in terms {
            documentFrequency[term] = passages.reduce(0) {
                $0 + (Self.contains(term, in: $1.text) ? 1 : 0)
            }
        }

        var coverage = [Double](repeating: 0, count: passages.count)
        var titleHits = [Double](repeating: 0, count: passages.count)

        for (index, passage) in passages.enumerated() {
            var covered = 0.0
            var totalWeight = 0.0
            for term in terms {
                let frequency = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - frequency + 0.5) / (frequency + 0.5))
                totalWeight += idf
                if Self.contains(term, in: passage.text) {
                    covered += idf
                    let occurrences = min(Self.count(term, in: passage.text), 3)
                    covered += idf * 0.1 * Double(occurrences - 1)
                }
            }
            var value = totalWeight > 0 ? min(1.0, covered / totalWeight) : 0
            // Phrase hits are a precision signal; fold them into coverage rather
            // than adding a fourth ranked list (cheaper, same effect).
            if !phrases.isEmpty {
                let hits = phrases.filter { Self.contains($0, in: passage.text) }.count
                value += 0.25 * (Double(hits) / Double(phrases.count))
            }
            coverage[index] = value

            let inTitle = terms.filter { Self.contains($0, in: passage.title) }.count
            titleHits[index] = Double(inTitle) / Double(terms.count)
        }

        let byBM25 = Self.positions(count: passages.count) { lhs, rhs in
            passages[lhs].bm25 != passages[rhs].bm25
                ? passages[lhs].bm25 < passages[rhs].bm25
                : passages[lhs].id < passages[rhs].id
        }
        let byCoverage = Self.positions(count: passages.count) { lhs, rhs in
            coverage[lhs] != coverage[rhs] ? coverage[lhs] > coverage[rhs] : passages[lhs].id < passages[rhs].id
        }
        let byTitle = Self.positions(count: passages.count) { lhs, rhs in
            titleHits[lhs] != titleHits[rhs] ? titleHits[lhs] > titleHits[rhs] : passages[lhs].id < passages[rhs].id
        }

        var ranked: [Passage] = []
        ranked.reserveCapacity(passages.count)
        for index in 0..<passages.count {
            var passage = passages[index]
            passage.lexicalScore = coverage[index]
            passage.score = bm25Weight / (k + Double(byBM25[index]))
                + coverageWeight / (k + Double(byCoverage[index]))
                + titleWeight / (k + Double(byTitle[index]))
            ranked.append(passage)
        }

        return ranked.sorted {
            if abs($0.score - $1.score) > 1e-12 { return $0.score > $1.score }
            return $0.id < $1.id
        }
    }

    /// 0-based rank of each element under a strict weak ordering.
    static func positions(count: Int, by areInIncreasingOrder: (Int, Int) -> Bool) -> [Int] {
        var result = [Int](repeating: 0, count: count)
        for (position, index) in (0..<count).sorted(by: areInIncreasingOrder).enumerated() {
            result[index] = position
        }
        return result
    }

    /// Drops near-duplicate passages, keeping the best-scoring one. Wikipedia
    /// extracts repeat lead paragraphs across neighbouring chunks.
    public func dedupe(_ passages: [Passage], jaccardThreshold: Double = 0.55) -> [Passage] {
        var kept: [Passage] = []
        var seenTokens: [Set<String>] = []
        for passage in passages {
            let tokens = Set(TextNormalizer.rawTerms(passage.text).map(TextNormalizer.stem))
            var duplicate = false
            for existing in seenTokens {
                let intersection = Double(tokens.intersection(existing).count)
                let union = Double(tokens.union(existing).count)
                if union > 0, intersection / union >= jaccardThreshold {
                    duplicate = true
                    break
                }
            }
            if !duplicate {
                kept.append(passage)
                seenTokens.append(tokens)
            }
        }
        return kept
    }

    static func contains(_ term: String, in text: String) -> Bool {
        TextNormalizer.fold(text).contains(term)
    }

    static func count(_ term: String, in text: String) -> Int {
        let folded = TextNormalizer.fold(text)
        guard !term.isEmpty else { return 0 }
        var count = 0
        var range = folded.startIndex..<folded.endIndex
        while let found = folded.range(of: term, range: range) {
            count += 1
            if found.upperBound >= folded.endIndex { break }
            range = found.upperBound..<folded.endIndex
            if count > 32 { break }
        }
        return count
    }
}
