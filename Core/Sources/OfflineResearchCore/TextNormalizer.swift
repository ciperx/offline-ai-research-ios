import Foundation

/// Normalisation + light stemming shared by the query builder and the reranker.
/// Pure Foundation: identical behaviour in the app, in unit tests and in the
/// Linux verification harness (`swift test` inside `Core/`).
public enum TextNormalizer {

    /// Small on purpose: enough to kill noise, not enough to remove meaning.
    public static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but",
        "by", "can", "cannot", "could", "did", "do", "does", "doing", "down", "during", "each",
        "few", "for", "from", "further", "had", "has", "have", "having", "he", "her", "here",
        "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into", "is", "it",
        "its", "itself", "just", "me", "more", "most", "my", "myself", "no", "nor", "not", "now",
        "of", "off", "on", "once", "only", "or", "other", "our", "ours", "ourselves", "out", "over",
        "own", "same", "she", "should", "so", "some", "such", "than", "that", "the", "their",
        "theirs", "them", "themselves", "then", "there", "these", "they", "this", "those",
        "through", "to", "too", "under", "until", "up", "very", "was", "we", "were", "what",
        "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would", "you",
        "your", "yours", "yourself", "yourselves", "please", "tell", "explain", "describe",
        "give", "want", "need", "know", "mean", "means", "meaning", "difference"
    ]

    /// Words a term-frequency model would discard but that carry the question's
    /// intent. They survive normalisation and get a small boost when ranking.
    /// Interrogatives ("why", "how") stay out: they are too common to retrieve on
    /// and are already excluded by `stopwords`.
    public static let intentTerms: Set<String> = [
        "cause", "causes", "effect", "effects", "risk", "risks", "versus", "vs",
        "better", "worse", "faster", "slower", "cheaper", "tradeoff", "tradeoffs", "compare"
    ]

    public static let abbreviations: [String] = [
        "e.g.", "i.e.", "etc.", "vs.", "cf.", "al.", "Dr.", "Mr.", "Ms.", "Mrs.", "Fig.", "No.",
        "St.", "Jr.", "Sr.", "approx.", "ca.", "Ph.D."
    ]

    /// Lowercase + strip diacritics + width-fold. Matches SQLite's
    /// `unicode61 remove_diacritics 2` closely enough to agree on term identity.
    public static func fold(_ input: String) -> String {
        input
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// Splits identifiers and compounds so `TCP/IP`, `full-text` and
    /// `retrievalAugmentedGeneration` all yield useful terms. camelCase is split
    /// *before* folding, otherwise the case information is already gone.
    public static func rawTerms(_ input: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for character in input {
            if character.isUppercase, let last = previous, last.isLowercase || last.isNumber {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }
        var prepared = fold(spaced)
        prepared = prepared.replacingOccurrences(of: "'s", with: " ")
        prepared = prepared.replacingOccurrences(of: "'", with: "")
        let separators = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "+#"))
            .inverted
        return prepared.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// Unique content terms, unstemmed, in priority order. Used for the FTS
    /// expression (SQLite does not stem, so raw forms matter) and as a base for
    /// the stemmed variants.
    public static func queryTokens(_ input: String) -> [String] {
        var seen = Set<String>()
        var content: [String] = []
        var intent: [String] = []
        for token in rawTerms(input) where token.count > 1 {
            guard seen.insert(token).inserted else { continue }
            if stopwords.contains(token) { continue }
            if intentTerms.contains(token) { intent.append(token) } else { content.append(token) }
        }
        return content + intent
    }

    /// Stemmed content terms, used by the reranker's substring matching.
    public static func queryTerms(_ input: String) -> [String] {
        var seen = Set<String>()
        return queryTokens(input).map(stem).filter { seen.insert($0).inserted }
    }

    /// Conservative suffix stripping. Rules are ordered most-specific-first and
    /// each has a minimum remaining length so "gas", "class", "us" survive.
    public static func stem(_ word: String) -> String {
        let count = word.count
        if count <= 3 { return word }
        if word.hasSuffix("ies"), count >= 5 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        for sibilant in ["ches", "shes", "xes", "zes", "ses"] where word.hasSuffix(sibilant) {
            return String(word.dropLast(2))   // "boxes" -> "box", "classes" -> "class"
        }
        if word.hasSuffix("s"), count >= 4,
           !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast(1))    // "genes" -> "gene"
        }
        if word.hasSuffix("ing"), count >= 6 { return String(word.dropLast(3)) }
        if word.hasSuffix("ed"), count >= 5 { return String(word.dropLast(2)) }
        return word
    }

    /// Sentence split that survives abbreviations and decimal numbers.
    /// Abbreviations are protected with a placeholder before scanning, then
    /// restored, which keeps the implementation regex-free and testable.
    public static func sentences(_ text: String) -> [String] {
        let placeholder = "\u{2063}"   // INVISIBLE SEPARATOR, never in source prose
        var working = text
        for abbreviation in abbreviations {
            working = working.replacingOccurrences(of: abbreviation, with: abbreviation.replacingOccurrences(of: ".", with: placeholder))
        }

        var out: [String] = []
        var buffer = ""
        let characters = Array(working)
        for (index, character) in characters.enumerated() {
            buffer.append(character)
            let isTerminator = character == "." || character == "!" || character == "?" || character == "\n"
            guard isTerminator else { continue }

            // "22.5" is not a sentence boundary.
            if character == ".", index > 0, index + 1 < characters.count,
               characters[index - 1].isNumber, characters[index + 1].isNumber {
                continue
            }

            // Look ahead: a sentence ends only if whitespace follows and the next
            // non-space character starts a new sentence.
            var lookahead = index + 1
            while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\"" {
                lookahead += 1
            }
            let atEnd = lookahead >= characters.count
            let nextIsUpper = !atEnd && (characters[lookahead].isUppercase || characters[lookahead].isNumber)
            let isNewline = character == "\n"
            guard atEnd || isNewline || nextIsUpper else { continue }

            let candidate = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !candidate.isEmpty else { continue }
            out.append(candidate)
        }

        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }

        return out.map { $0.replacingOccurrences(of: placeholder, with: ".") }
    }
}
