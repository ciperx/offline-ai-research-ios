import XCTest
@testable import OfflineResearchCore

final class ExtractiveAndCatalogTests: XCTestCase {

    private func passage(_ id: Int, _ title: String, _ text: String, score: Double = 0.5) -> Passage {
        var p = Passage(id: id, docID: id, title: title, url: "https://example.org/\(id)",
                        text: text, ordinal: 0, bm25: -1)
        p.score = score
        return p
    }

    func testComposePicksRelevantSentencesWithCitations() {
        let passages = [
            passage(1, "Antibiotic resistance",
                    "Antibiotic resistance is a heritable ability of bacteria to survive drug exposure. " +
                    "Resistance spreads through plasmids and horizontal gene transfer in hospitals. " +
                    "Hand hygiene reduces transmission between patients."),
            passage(2, "Immune system", "The immune system recognises pathogens through pattern receptors.", score: 0.2)
        ]
        let composed = ExtractiveComposer().compose(question: "how does resistance spread in hospitals", passages: passages)
        XCTAssertFalse(composed.answer.isEmpty)
        XCTAssertTrue(composed.answer.contains("[1]"))
        XCTAssertGreaterThanOrEqual(composed.sentencesUsed, 1)
        XCTAssertEqual(composed.citations.first?.title, "Antibiotic resistance")
    }

    func testComposeReportsEmptyCorpusExplicitly() {
        let composed = ExtractiveComposer().compose(question: "anything", passages: [])
        XCTAssertTrue(composed.answer.contains("does not cover"))
        XCTAssertTrue(composed.citations.isEmpty)
        XCTAssertEqual(composed.sentencesUsed, 0)
    }

    func testComposeRespectsCharacterBudget() {
        let long = (0..<30).map { _ in "Resistance spreads through plasmids and horizontal transfer in hospitals." }
            .joined(separator: " ")
        let composed = ExtractiveComposer(maxSentences: 8, maxCharacters: 300)
            .compose(question: "resistance spread", passages: [passage(1, "Antibiotic resistance", long)])
        XCTAssertLessThanOrEqual(composed.answer.count, 320)
    }

    func testComposeIsDeterministic() {
        let passages = [passage(1, "Antibiotic resistance",
                                "Resistance spreads via plasmids. Hospitals amplify resistance. Genes transfer horizontally.")]
        let a = ExtractiveComposer().compose(question: "resistance plasmids", passages: passages).answer
        let b = ExtractiveComposer().compose(question: "resistance plasmids", passages: passages).answer
        XCTAssertEqual(a, b)
    }

    // MARK: - ModelCatalog

    func testCatalogDecodesAndValidates() throws {
        let json = """
        {
          "schema": 1,
          "default": "small-q4",
          "models": [{
            "id": "small-q4",
            "name": "Small Q4",
            "family": "Qwen2.5",
            "parameters": "0.5B",
            "quantization": "Q4_K_M",
            "filename": "small-q4.gguf",
            "size_bytes": 491400032,
            "sha256": "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
            "url": "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
            "context_train": 32768,
            "recommended_context": 4096,
            "ram_estimate_mb": 900,
            "license": "Apache-2.0",
            "notes": "test"
          }]
        }
        """
        let catalog = try ModelCatalog.decode(Data(json.utf8))
        XCTAssertEqual(catalog.defaultProfile?.id, "small-q4")
        XCTAssertEqual(catalog.profile(id: "small-q4")?.sizeBytes, 491400032)
        XCTAssertTrue(catalog.validate().isEmpty)
    }

    func testCatalogRejectsBadChecksumAndMissingDefault() {
        let json = """
        {"schema": 1, "default": "missing", "models": [{
          "id": "x", "name": "X", "family": "F", "parameters": "1B", "quantization": "Q4_K_M",
          "filename": "x.gguf", "size_bytes": 1, "sha256": "abc", "url": "http://insecure/x.gguf",
          "context_train": 1024, "recommended_context": 512, "ram_estimate_mb": 10,
          "license": "MIT", "notes": ""
        }]}
        """
        XCTAssertThrowsError(try ModelCatalog.decode(Data(json.utf8))) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("sha256"))
            XCTAssertTrue(message.contains("default"))
        }
    }

    func testFallbackCatalogIsUsable() {
        let catalog = ModelCatalogFallback.catalog()
        XCTAssertTrue(catalog.validate().isEmpty)
        XCTAssertEqual(catalog.defaultProfile?.parameters, "1.5B")
    }

    // MARK: - SamplingConfig

    func testSamplingClampKeepsValuesInRange() {
        let wild = SamplingConfig(temperature: 9, topP: 3, topK: 9999, minP: -1,
                                  repeatPenalty: 0.1, repeatLastN: 8, maxTokens: 99999,
                                  seed: 1, stopStrings: [])
        let clamped = wild.clamped()
        XCTAssertEqual(clamped.temperature, 2)
        XCTAssertEqual(clamped.topP, 1)
        XCTAssertEqual(clamped.topK, 200)
        XCTAssertEqual(clamped.minP, 0)
        XCTAssertEqual(clamped.repeatPenalty, 1)
        XCTAssertEqual(clamped.maxTokens, 4096)
    }

    func testDeterministicPresetIsGreedy() {
        XCTAssertEqual(SamplingConfig.deterministic.temperature, 0)
        XCTAssertEqual(SamplingConfig.deterministic.topK, 1)
    }
}
