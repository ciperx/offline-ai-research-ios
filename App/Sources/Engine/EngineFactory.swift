import Foundation

/// Chooses the backend at runtime. The app never crashes because a model is
/// missing: it degrades to extractive retrieval and says so in the UI.
enum EngineFactory {

    struct Resolution {
        let engine: ResearchEngine
        let note: String
    }

    static func make(modelPath: String?, contextTokens: Int) -> Resolution {
        #if NO_LLAMA_ENGINE
        return Resolution(engine: ExtractiveEngine(),
                          note: "Built without llama.cpp (NO_LLAMA_ENGINE). Retrieval only.")
        #else
        guard let path = modelPath, FileManager.default.fileExists(atPath: path) else {
            return Resolution(engine: ExtractiveEngine(),
                              note: "No GGUF installed yet — retrieval-only mode. Add a model in Settings.")
        }
        return Resolution(engine: LlamaEngine(), note: "llama.cpp backend for \(URL(fileURLWithPath: path).lastPathComponent)")
        #endif
    }
}
