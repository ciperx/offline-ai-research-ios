import Foundation

#if !NO_LLAMA_ENGINE

/// llama.cpp backend.
///
/// Threading model: every C call happens on a single serial queue owned by this
/// object. `answer(...)` returns a stream immediately and does the work on a
/// detached task; `unload()` flips a flag that the decode loop checks between
/// tokens. This keeps SwiftUI's main thread free and makes cancellation
/// predictable without a lock-free dance around the context pointer.
final class LlamaEngine: ResearchEngine, @unchecked Sendable {

    private let state = NSLock()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: OpaquePointer?
    private var loadedPath: String?
    private var loadedContextTokens: Int = 0
    private var cancelRequested = false
    private var generating = false

    private(set) var descriptor = EngineDescriptor(
        kind: .llama,
        name: "llama.cpp",
        detail: "GGUF inference on CPU/Metal"
    )

    var isReady: Bool {
        state.lock(); defer { state.unlock() }
        return model != nil && context != nil
    }

    init() {
        llama_backend_init()
    }

    deinit {
        unload()
        llama_backend_free()
    }

    // MARK: - Lifecycle

    func prepare(modelPath: String?, contextTokens: Int) async throws {
        guard let path = modelPath, FileManager.default.fileExists(atPath: path) else {
            throw EngineError.modelMissing(modelPath ?? "<none>")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.loadLocked(path: path, contextTokens: contextTokens)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadLocked(path: String, contextTokens: Int) throws {
        state.lock()
        let alreadyLoaded = loadedPath == path && loadedContextTokens == contextTokens && context != nil
        state.unlock()
        if alreadyLoaded { return }

        unload()

        var modelParams = llama_model_default_params()
        // -1 == "all layers on GPU". On a CPU-only build this is ignored.
        modelParams.n_gpu_layers = -1
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        modelParams.use_extra_bufts = true

        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw EngineError.modelLoadFailed("llama_model_load_from_file returned NULL for \(path)")
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            throw EngineError.modelLoadFailed("model has no vocabulary")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(512, contextTokens))
        contextParams.n_batch = UInt32(min(1024, max(128, contextTokens / 2)))
        contextParams.n_ubatch = contextParams.n_batch
        let cores = ProcessInfo.processInfo.activeProcessorCount
        contextParams.n_threads = Int32(max(2, min(6, cores - 1)))
        contextParams.n_threads_batch = Int32(max(2, min(8, cores)))
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        contextParams.no_perf = false

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw EngineError.contextCreationFailed
        }

        state.lock()
        model = loadedModel
        vocab = loadedVocab
        context = loadedContext
        loadedPath = path
        loadedContextTokens = Int(contextParams.n_ctx)
        state.unlock()

        descriptor = EngineDescriptor(
            kind: .llama,
            name: "llama.cpp",
            detail: "ctx \(contextParams.n_ctx) · threads \(contextParams.n_threads)"
        )
    }

    func unload() {
        state.lock()
        cancelRequested = true
        let oldSampler = sampler
        let oldContext = context
        let oldModel = model
        sampler = nil
        context = nil
        model = nil
        vocab = nil
        loadedPath = nil
        state.unlock()

        if let oldSampler { llama_sampler_free(oldSampler) }
        if let oldContext { llama_free(oldContext) }
        if let oldModel { llama_model_free(oldModel) }
    }

    // MARK: - Generation

    func answer(question: String,
                passages: [Passage],
                history: [PromptBuilder.ChatMessage],
                config: SamplingConfig) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try self.run(question: question, passages: passages, history: history,
                                 config: config, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.requestCancel()
            }
        }
    }

    private func requestCancel() {
        state.lock()
        cancelRequested = true
        state.unlock()
    }

    private func isCancelled() -> Bool {
        state.lock(); defer { state.unlock() }
        return cancelRequested
    }

    private func run(question: String,
                     passages: [Passage],
                     history: [PromptBuilder.ChatMessage],
                     config: SamplingConfig,
                     continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) throws {

        state.lock()
        guard !generating else {
            state.unlock()
            throw EngineError.alreadyGenerating
        }
        generating = true
        cancelRequested = false
        let context = self.context
        let vocab = self.vocab
        let model = self.model
        state.unlock()

        defer {
            state.lock(); generating = false; state.unlock()
        }

        guard let context, let vocab, let model else { throw EngineError.modelMissing(loadedPath ?? "<none>") }

        let settings = config.clamped()
        let builder = PromptBuilder(style: .grounded,
                                    maxContextTokens: loadedContextTokens,
                                    reserveForAnswer: settings.maxTokens)
        let built = builder.build(question: question, passages: passages, history: history)
        let prompt = Self.applyChatTemplate(messages: built.messages, model: model)

        // Reset KV state: every turn is a fresh prompt. Simple and predictable;
        // cross-turn cache reuse is a documented future optimisation.
        if let memory = llama_get_memory(context) {
            llama_memory_clear(memory, true)
        }

        var tokens = [llama_token](repeating: 0, count: max(64, prompt.utf8.count + 32))
        var promptCount = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count),
                                         &tokens, Int32(tokens.count), true, true)
        if promptCount < 0 {
            let needed = Int(-promptCount)
            tokens = [llama_token](repeating: 0, count: needed + 8)
            promptCount = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count),
                                         &tokens, Int32(tokens.count), true, true)
        }
        guard promptCount > 0 else { throw EngineError.tokenizationFailed }

        let promptTokenCount = Int(promptCount)
        let usable = min(promptTokenCount, Int(max(1, loadedContextTokens - settings.maxTokens)))
        guard usable > 0 else { throw EngineError.contextCreationFailed }

        // Feed the prompt in one batch (n_batch is sized for it in prepare()).
        var truncated = Array(tokens.prefix(usable))
        var batch = llama_batch_get_one(&truncated, Int32(truncated.count))
        let decodeStatus = llama_decode(context, batch)
        guard decodeStatus == 0 else { throw EngineError.decodeFailed(decodeStatus) }

        // Sampler chain: penalties -> top_k -> top_p -> min_p -> temp -> dist.
        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else {
            throw EngineError.contextCreationFailed
        }
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            llama_vocab_n_tokens(vocab),
            Int32(settings.repeatLastN),
            Float(settings.repeatPenalty),
            0.0,
            0.0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(settings.topK)))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(settings.topP), 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(settings.minP), 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(settings.temperature)))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(settings.seed))
        defer { llama_sampler_free(chain) }

        let start = DispatchTime.now()
        var firstTokenAt: DispatchTime?
        var generated = 0
        var output = ""
        var finish: FinishReason = .maxTokens
        var stopMatched = false

        while generated < settings.maxTokens {
            if isCancelled() || Task.isCancelled {
                finish = .cancelled
                break
            }

            let token = llama_sampler_sample(chain, context, -1)
            llama_sampler_accept(chain, token)

            if llama_vocab_is_eog(vocab, token) {
                finish = .endOfGeneration
                break
            }

            let piece = Self.piece(for: token, vocab: vocab)
            if piece.isEmpty { continue }

            output += piece
            if firstTokenAt == nil { firstTokenAt = DispatchTime.now() }
            generated += 1
            continuation.yield(.token(piece))

            if let hit = settings.stopStrings.first(where: { !$0.isEmpty && output.hasSuffix($0) }) {
                _ = hit
                finish = .stopString
                stopMatched = true
                break
            }

            var single = token
            var nextBatch = llama_batch_get_one(&single, 1)
            let status = llama_decode(context, nextBatch)
            if status != 0 {
                throw EngineError.decodeFailed(status)
            }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let ttft = firstTokenAt.map {
            Double($0.uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        } ?? 0

        continuation.yield(.stats(GenerationStats(
            promptTokens: promptTokenCount,
            generatedTokens: generated,
            tokensPerSecond: elapsed > 0 ? Double(generated) / elapsed : 0,
            millisecondsToFirstToken: Int(ttft),
            contextTokens: loadedContextTokens,
            modelName: loadedPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "model"
        )))
        continuation.yield(.finished(reason: stopMatched ? .stopString : finish))
    }

    // MARK: - C helpers

    /// Applies the model's own chat template when llama.cpp knows it, otherwise
    /// falls back to ChatML (what Qwen2.5 and SmolLM2 both expect).
    static func applyChatTemplate(messages: [PromptBuilder.ChatMessage], model: OpaquePointer) -> String {
        var cMessages: [llama_chat_message] = []
        var storage: [UnsafeMutablePointer<CChar>] = []
        defer { storage.forEach { free($0) } }

        for message in messages {
            let role = strdup(message.role)
            let content = strdup(message.content)
            if let role, let content {
                storage.append(role)
                storage.append(content)
                cMessages.append(llama_chat_message(role: UnsafePointer(role),
                                                    content: UnsafePointer(content)))
            }
        }

        let template = llama_model_chat_template(model, nil)
        var bufferSize = 4096
        for _ in 0..<4 {
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let written = llama_chat_apply_template(template, cMessages, cMessages.count, true,
                                                    &buffer, Int32(bufferSize))
            if written > 0 && Int(written) <= bufferSize {
                return String(cString: buffer)
            }
            if written > bufferSize {
                bufferSize = Int(written) + 64
                continue
            }
            break
        }

        // Manual ChatML fallback.
        var out = ""
        for message in messages {
            out += "<|im_start|>\(message.role)\n\(message.content)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    static func piece(for token: llama_token, vocab: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if length > 0 && Int(length) <= buffer.count {
            return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if length < 0 {
            var big = [CChar](repeating: 0, count: Int(-length) + 8)
            let retry = llama_token_to_piece(vocab, token, &big, Int32(big.count), 0, true)
            if retry > 0 {
                return String(decoding: big.prefix(Int(retry)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return ""
    }
}

#endif
