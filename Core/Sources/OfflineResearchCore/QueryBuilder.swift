import Foundation

/// Turns a natural-language question into a safe FTS5 MATCH expression.
///
/// The corpus is indexed with `unicode61 remove_diacritics 2`, which does not
/// stem. To get stemming-like recall without a custom tokenizer we emit both the
/// raw term and its stemmed variant, each as a *prefix* query when long enough:
///
///     "batteries"* OR "battery"* OR "resistance"* OR ...
///
/// Every variant is quoted, so user input can never be parsed as FTS5 syntax.
public struct QueryBuilder {

    public struct Expression: Equatable {
        /// OR of every raw/stemmed variant — first retrieval pass.
        public let primary: String
        /// AND of the first three stems — used when `primary` returns too little.
        public let strict: String
        /// Stemmed terms in priority order, used by the reranker.
        public let terms: [String]
        /// Raw content tokens, kept for diagnostics.
        public let tokens: [String]
        /// Bigrams from the question, used for phrase boosting.
        public let phrases: [String]

        public var isEmpty: Bool { primary.isEmpty }
    }

    public var maxTerms: Int
    public var maxPhrases: Int
    public var prefixMinimumLength: Int

    public init(maxTerms: Int = 12, maxPhrases: Int = 3, prefixMinimumLength: Int = 4) {
        self.maxTerms = maxTerms
        self.maxPhrases = maxPhrases
        self.prefixMinimumLength = prefixMinimumLength
    }

    public func build(_ question: String) -> Expression {
        let tokens = Array(TextNormalizer.queryTokens(question).prefix(maxTerms))
        let stems = tokens.map(TextNormalizer.stem)

        var variants: [String] = []
        var seen = Set<String>()
        for candidate in tokens + stems where candidate.count > 1 {
            if seen.insert(candidate).inserted { variants.append(candidate) }
        }

        let primary = variants.map { prefixTerm($0) }.joined(separator: " OR ")
        let strictTerms = Array(Set(stems).prefix(min(3, stems.count))).map { prefixTerm($0) }
        let strict = strictTerms.joined(separator: " AND ")
        return Expression(primary: primary,
                          strict: strict,
                          terms: stems,
                          tokens: tokens,
                          phrases: Self.phrases(from: question, limit: maxPhrases))
    }

    /// Quoted term, promoted to a prefix query when long enough to be selective.
    public func prefixTerm(_ term: String) -> String {
        let quoted = Self.quote(term)
        return term.count >= prefixMinimumLength ? quoted + "*" : quoted
    }

    /// Escapes a single term for FTS5: wrap in double quotes, double any internal
    /// quote. Everything else is literal inside a quoted string.
    public static func quote(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Two-word phrases for a phrase-boost pass. Question scaffolding is trimmed
    /// first so "what is X" does not produce the phrase "what is".
    public static func phrases(from question: String, limit: Int) -> [String] {
        var words = TextNormalizer.rawTerms(question)
        guard words.count >= 2 else { return [] }
        let leading: Set<String> = ["what", "why", "how", "when", "where", "which", "who", "does",
                                    "do", "is", "are", "can", "explain", "describe", "compare", "tell"]
        let trailing: Set<String> = ["mean", "means", "meaning", "work", "works", "happen", "happens"]
        while let first = words.first, leading.contains(first) { words.removeFirst() }
        while let last = words.last, trailing.contains(last) { words.removeLast() }
        guard words.count >= 2 else { return [] }

        var out: [String] = []
        for index in 0..<(words.count - 1) where out.count < limit {
            let a = words[index], b = words[index + 1]
            if !TextNormalizer.stopwords.contains(a), !TextNormalizer.stopwords.contains(b) {
                out.append("\(a) \(b)")
            }
        }
        return out
    }
}
