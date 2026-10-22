import Foundation

/// Builds the chat prompt. Two variants:
///  * `.grounded` - retrieved passages injected as numbered sources; the model is
///    instructed to cite them and to say when the corpus does not answer.
///  * `.plain` - no retrieval (still offline).
///
/// The prompt is deliberately terse: small models follow short instructions far
/// better than long ones, and every token of scaffolding is a token not spent on
/// context.
public struct PromptBuilder {

    public enum Style: String, Codable {
        case grounded
        case plain
    }

    public struct ChatMessage: Codable, Equatable {
        public let role: String   // "system" | "user" | "assistant"
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct BuiltPrompt {
        public let messages: [ChatMessage]
        public let citations: [Citation]
        public let usedPassages: [Passage]
        public let estimatedTokens: Int
        public let trimmed: Bool
    }

    public var style: Style
    public var maxContextTokens: Int
    public var reserveForAnswer: Int
    public var maxPassages: Int

    public init(style: Style = .grounded,
                maxContextTokens: Int = 4096,
                reserveForAnswer: Int = 700,
                maxPassages: Int = 5) {
        self.style = style
        self.maxContextTokens = maxContextTokens
        self.reserveForAnswer = reserveForAnswer
        self.maxPassages = maxPassages
    }

    public static let systemGrounded = """
    You are an offline research assistant running on a phone with no internet.
    Answer only from the numbered sources. Cite them like [1] or [2] after each claim.
    Prefer explanation, comparison and synthesis over lists of facts.
    If the sources do not contain the answer, say "The local corpus does not cover this." and stop.
    Never mention the internet, never offer to search, never invent sources.
    Keep answers under 220 words unless the question asks for detail.
    """

    public static let systemPlain = """
    You are an offline research assistant running on a phone with no internet.
    Answer from your own knowledge. Be concrete and explain reasoning briefly.
    If you are unsure, say which part is uncertain. Never mention the internet or offer to search.
    """

    public func build(question: String, passages: [Passage], history: [ChatMessage] = []) -> BuiltPrompt {
        let budget = max(256, maxContextTokens - reserveForAnswer - TokenEstimator.estimate(question) - 120)
        let capped = Array(passages.prefix(maxPassages))
        let kept = TokenEstimator.trim(capped, budget: budget) { Self.renderSource($0, index: 0) }
        let trimmed = kept.count < capped.count || kept.map(\.id) != capped.prefix(kept.count).map(\.id)

        var citations: [Citation] = []
        var sourceBlock = ""
        for (offset, passage) in kept.enumerated() {
            let index = offset + 1
            citations.append(Citation(index: index, title: passage.title, url: passage.url, passageID: passage.id))
            sourceBlock += Self.renderSource(passage, index: index) + "\n\n"
        }

        var messages: [ChatMessage] = []
        messages.append(ChatMessage(role: "system", content: style == .grounded ? Self.systemGrounded : Self.systemPlain))

        // Keep at most the last two exchanges: context is scarce and small models
        // degrade quickly with long histories.
        for turn in history.suffix(4) {
            messages.append(turn)
        }

        let userContent: String
        if style == .grounded, !kept.isEmpty {
            userContent = """
            Sources:
            \(sourceBlock.trimmingCharacters(in: .whitespacesAndNewlines))

            Question: \(question)
            Answer with citations:
            """
        } else {
            userContent = "Question: \(question)\nAnswer:"
        }
        messages.append(ChatMessage(role: "user", content: userContent))

        let estimate = TokenEstimator.estimate(messages.map(\.content).joined(separator: "\n"))
        return BuiltPrompt(messages: messages, citations: citations, usedPassages: kept,
                           estimatedTokens: estimate, trimmed: trimmed)
    }

    public static func renderSource(_ passage: Passage, index: Int) -> String {
        let body = passage.text.replacingOccurrences(of: "\n", with: " ")
        let clipped = body.count <= 900 ? body : String(body.prefix(900)) + "..."
        return "[\(index)] \(passage.title): \(clipped)"
    }
}
