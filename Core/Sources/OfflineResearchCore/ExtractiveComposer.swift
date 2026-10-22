import Foundation

/// Model-free answer path.
///
/// When no GGUF is installed (fresh clone, simulator, CI) the app still answers:
/// it selects the sentences from the retrieved passages that best cover the
/// question, orders them, and attaches citations. This is extractive, not
/// generative - it cannot synthesise new claims, and the UI says so explicitly.
///
/// It also runs *after* a generative answer as a grounding fallback when the
/// model returns nothing or refuses.
public struct ExtractiveComposer {

    public struct Composed {
        public let answer: String
        public let citations: [Citation]
        public let sentencesUsed: Int
    }

    public var maxSentences: Int
    public var maxCharacters: Int

    public init(maxSentences: Int = 5, maxCharacters: Int = 900) {
        self.maxSentences = maxSentences
        self.maxCharacters = maxCharacters
    }

    public func compose(question: String, passages: [Passage]) -> Composed {
        guard !passages.isEmpty else {
            return Composed(answer: "The local corpus does not cover this. Add documents with Scripts/fetch_corpus.py and rebuild the index.",
                            citations: [], sentencesUsed: 0)
        }

        let terms = TextNormalizer.queryTerms(question)
        let phrases = QueryBuilder.phrases(from: question, limit: 3)
        var candidates: [(sentence: String, citation: Int, score: Double, order: Int)] = []
        var citations: [Citation] = []
        var order = 0

        for (offset, passage) in passages.enumerated() {
            let citationIndex = offset + 1
            citations.append(Citation(index: citationIndex, title: passage.title,
                                      url: passage.url, passageID: passage.id))
            let sentences = TextNormalizer.sentences(passage.text)
            for sentence in sentences {
                order += 1
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 40, trimmed.count <= 420 else { continue }
                let score = scoreSentence(trimmed, terms: terms, phrases: phrases,
                                          passageScore: passage.score, position: order)
                candidates.append((trimmed, citationIndex, score, order))
            }
        }

        guard !candidates.isEmpty else {
            let lead = passages[0]
            citations = [Citation(index: 1, title: lead.title, url: lead.url, passageID: lead.id)]
            return Composed(answer: "\(lead.preview) [1]", citations: citations, sentencesUsed: 1)
        }

        candidates.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }

        // MMR-lite: prefer sentences that do not repeat words we already used.
        var chosen: [(sentence: String, citation: Int, score: Double, order: Int)] = []
        var usedTokens = Set<String>()
        for candidate in candidates {
            let tokens = Set(TextNormalizer.rawTerms(candidate.sentence).map(TextNormalizer.stem))
            let novel = tokens.subtracting(usedTokens)
            let novelty = tokens.isEmpty ? 0 : Double(novel.count) / Double(tokens.count)
            guard novelty >= 0.45 || chosen.isEmpty else { continue }
            chosen.append(candidate)
            usedTokens.formUnion(tokens)
            if chosen.count >= maxSentences { break }
        }

        // Reading order beats score order once the set is chosen.
        chosen.sort { $0.order < $1.order }
        var body = ""
        var length = 0
        var usedCount = 0
        for item in chosen {
            let withCitation = "\(item.sentence) [\(item.citation)]"
            if length + withCitation.count > maxCharacters && usedCount > 0 { break }
            body += (body.isEmpty ? "" : " ") + withCitation
            length += withCitation.count
            usedCount += 1
        }

        let distinct = Set(chosen.prefix(usedCount).map(\.citation)).sorted()
        let keep = citations.filter { distinct.contains($0.index) }
        return Composed(answer: body, citations: keep, sentencesUsed: usedCount)
    }

    func scoreSentence(_ sentence: String, terms: [String], phrases: [String],
                       passageScore: Double, position: Int) -> Double {
        let folded = TextNormalizer.fold(sentence)
        var score = 0.0
        for term in terms where folded.contains(term) {
            score += 1.0
            if TextNormalizer.intentTerms.contains(term) { score += 0.5 }
        }
        for phrase in phrases where folded.contains(phrase) {
            score += 1.5
        }
        // Definition-style openers are usually the best single-sentence answer.
        if folded.hasPrefix("is ") || folded.hasPrefix("are ") || folded.contains(" is a ") ||
            folded.contains(" is the ") || folded.contains(" refers to ") {
            score += 0.75
        }
        // Numbers and units are strong signals in research questions.
        if sentence.contains(where: { $0.isNumber }) { score += 0.35 }
        // Slight preference for earlier sentences (article leads are denser).
        score += max(0, 0.4 - Double(position) * 0.01)
        score += passageScore * 1.5
        return score
    }
}
