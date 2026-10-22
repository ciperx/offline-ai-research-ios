import Foundation

/// Everything the UI needs from an inference backend. Two implementations ship:
///
///   * `LlamaEngine`      — llama.cpp + a GGUF file (generative)
///   * `ExtractiveEngine` — retrieval only, no weights (always available)
///
/// Both stream tokens so the chat UI behaves identically, and both are strictly
/// offline: no implementation is allowed to open a socket.
public protocol ResearchEngine: AnyObject, Sendable {
    var descriptor: EngineDescriptor { get }
    var isReady: Bool { get }

    /// Loads weights (or prepares the extractive path). Errors are user-facing.
    func prepare(modelPath: String?, contextTokens: Int) async throws

    /// Streams an answer. The stream finishes normally at end of generation and
    /// throws only on real failures (model missing, decode error, OOM).
    func answer(question: String,
                passages: [Passage],
                history: [PromptBuilder.ChatMessage],
                config: SamplingConfig) -> AsyncThrowingStream<EngineEvent, Error>

    func unload()
}

public struct EngineDescriptor: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case llama
        case extractive
    }

    public let kind: Kind
    public let name: String
    public let detail: String

    public init(kind: Kind, name: String, detail: String) {
        self.kind = kind
        self.name = name
        self.detail = detail
    }

    public static let extractive = EngineDescriptor(
        kind: .extractive,
        name: "Extractive (no model)",
        detail: "Answers by quoting the best-matching corpus sentences. No weights loaded."
    )
}

public enum EngineEvent: Sendable {
    case token(String)
    case stats(GenerationStats)
    case finished(reason: FinishReason)
}

public struct GenerationStats: Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let tokensPerSecond: Double
    public let millisecondsToFirstToken: Int
    public let contextTokens: Int
    public let modelName: String
}

public enum FinishReason: String, Sendable {
    case endOfGeneration = "eog"
    case maxTokens = "max_tokens"
    case stopString = "stop_string"
    case cancelled = "cancelled"
    case extractive = "extractive"
}

public enum EngineError: LocalizedError {
    case modelMissing(String)
    case modelLoadFailed(String)
    case contextCreationFailed
    case decodeFailed(Int32)
    case tokenizationFailed
    case cancelled
    case alreadyGenerating

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            return "No model file at \(path). Copy a .gguf into the app's Documents folder or pick one in Settings."
        case .modelLoadFailed(let detail):
            return "The model could not be loaded: \(detail)"
        case .contextCreationFailed:
            return "llama.cpp could not create a context. Try a smaller context size in Settings."
        case .decodeFailed(let code):
            return "llama_decode failed with code \(code). The model may be corrupt or the context too small."
        case .tokenizationFailed:
            return "The prompt could not be tokenised."
        case .cancelled:
            return "Generation cancelled."
        case .alreadyGenerating:
            return "A generation is already running."
        }
    }
}
