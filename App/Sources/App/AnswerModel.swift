import Foundation
import OfflineResearchCore

/// Thin SwiftUI adapter over the verified core APIs:
/// `CorpusStore.search` → `ExtractiveComposer.compose`.
/// The generative path (`LlamaEngine`) plugs in behind the same type once a GGUF
/// file is installed; this keeps the UI usable on a fresh clone and in CI.
@MainActor
final class AnswerModel: ObservableObject {
    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var citations: [Citation] = []
    @Published var status: String = "offline"
    @Published var busy: Bool = false

    private let store: CorpusStore?
    private let composer = ExtractiveComposer()

    init() {
        if let url = Bundle.main.url(forResource: "corpus", withExtension: "sqlite") {
            store = try? CorpusStore(path: url.path)
        } else {
            store = nil
        }
        if store == nil {
            status = "offline · corpus missing"
        }
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let store else { return }
        busy = true
        defer { busy = false }
        do {
            let expression = QueryBuilder().build(q)
            var passages: [Passage] = []
            if !expression.primary.isEmpty {
                passages = try store.search(expression: expression.primary, limit: 40)
            }
            if passages.count < 3, !expression.strict.isEmpty {
                let strict = try store.search(expression: expression.strict, limit: 40)
                if strict.count > passages.count { passages = strict }
            }
            let composed = composer.compose(question: q, passages: passages)
            answer = composed.answer
            citations = composed.citations
            status = "offline · \(passages.count) candidates · \(composed.sentencesUsed) sentences"
        } catch {
            answer = "Retrieval failed: \(error.localizedDescription)"
        }
    }
}
