import Foundation

/// Model-free backend. Retrieval still works (the index ships in the bundle), so
/// a fresh clone is usable in the simulator and on a device before any GGUF has
/// been copied over. Answers are extractive: real corpus sentences, cited, with
/// no synthesis.
///
/// This is also the fallback used when the generative engine fails mid-answer:
/// the UI never leaves the user with an empty screen.
final class ExtractiveEngine: ResearchEngine, @unchecked Sendable {

    private let composer = ExtractiveComposer()
    private(set) var isReady = true
    let descriptor = EngineDescriptor.extractive

    func prepare(modelPath: String?, contextTokens: Int) async throws {}

    func unload() {}

    func answer(question: String,
                passages: [Passage],
                history: [PromptBuilder.ChatMessage],
                config: SamplingConfig) -> AsyncThrowingStream<EngineEvent, Error> {
        let composed = composer.compose(question: question, passages: passages)
        return AsyncThrowingStream { continuation in
            // Chunked so the UI shows the same progressive rendering as the
            // generative path; no artificial delay beyond one runloop tick.
            let words = composed.answer.split(separator: " ", omittingEmptySubsequences: false)
            for (index, word) in words.enumerated() {
                if Task.isCancelled { break }
                continuation.yield(.token(index == 0 ? String(word) : " " + word))
            }
            continuation.yield(.stats(GenerationStats(
                promptTokens: 0,
                generatedTokens: words.count,
                tokensPerSecond: 0,
                millisecondsToFirstToken: 0,
                contextTokens: 0,
                modelName: "extractive"
            )))
            continuation.yield(.finished(reason: .extractive))
            continuation.finish()
        }
    }
}
