import Foundation

/// One indexed paragraph returned by retrieval.
public struct Passage: Identifiable, Hashable, Codable {
    public let id: Int
    public let docID: Int
    public let title: String
    public let url: String?
    public let text: String
    public let ordinal: Int
    /// Raw SQLite `bm25()` value. Lower is better; it is negative.
    public var bm25: Double
    /// Lexical overlap score computed in-process (0...1-ish).
    public var lexicalScore: Double
    /// Final blended score used for ordering. Higher is better.
    public var score: Double

    public init(id: Int, docID: Int, title: String, url: String?, text: String,
                ordinal: Int, bm25: Double = 0, lexicalScore: Double = 0, score: Double = 0) {
        self.id = id
        self.docID = docID
        self.title = title
        self.url = url
        self.text = text
        self.ordinal = ordinal
        self.bm25 = bm25
        self.lexicalScore = lexicalScore
        self.score = score
    }

    /// Short preview used in the sources sheet and in diagnostics.
    public var preview: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 220 ? flat : String(flat.prefix(220)) + "..."
    }
}

/// A citation as rendered in the answer and listed under it.
public struct Citation: Identifiable, Hashable, Codable {
    public let index: Int
    public let title: String
    public let url: String?
    public let passageID: Int

    public var id: Int { index }

    public init(index: Int, title: String, url: String?, passageID: Int) {
        self.index = index
        self.title = title
        self.url = url
        self.passageID = passageID
    }
}

/// Result of a retrieval call.
public struct RetrievalResult: Codable {
    public var question: String
    public var passages: [Passage]
    public var citations: [Citation]
    public var candidatesConsidered: Int
    public var elapsedMilliseconds: Int
    public var usedStrictFallback: Bool

    public init(question: String, passages: [Passage], citations: [Citation],
                candidatesConsidered: Int, elapsedMilliseconds: Int, usedStrictFallback: Bool) {
        self.question = question
        self.passages = passages
        self.citations = citations
        self.candidatesConsidered = candidatesConsidered
        self.elapsedMilliseconds = elapsedMilliseconds
        self.usedStrictFallback = usedStrictFallback
    }

    public static let empty = RetrievalResult(question: "", passages: [], citations: [],
                                              candidatesConsidered: 0, elapsedMilliseconds: 0,
                                              usedStrictFallback: false)
}
