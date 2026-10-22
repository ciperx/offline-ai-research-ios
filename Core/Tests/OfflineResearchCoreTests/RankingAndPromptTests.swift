import XCTest
@testable import OfflineResearchCore

final class RankingAndPromptTests: XCTestCase {

    private func passage(_ id: Int, _ title: String, _ text: String,
                         bm25: Double = -1, ordinal: Int = 0) -> Passage {
        Passage(id: id, docID: id, title: title, url: "https://example.org/\(id)",
                text: text, ordinal: ordinal, bm25: bm25)
    }

    func testRankerPrefersTitleAndCoverageOverRawBm25() {
        let weak = passage(1, "Ocean acidification", "Shellfish struggle when pH falls.", bm25: -2.0)
        let strong = passage(2, "Antibiotic resistance", "Resistance spreads through plasmids in hospitals.", bm25: -1.0)
        let ranked = Ranker().rank([weak, strong], terms: ["resistance", "hospital"], phrases: [])
        XCTAssertEqual(ranked.first?.id, 2)
    }

    func testRankerIsDeterministicForTies() {
        let a = passage(7, "A", "same text here", bm25: -1)
        let b = passage(3, "B", "same text here", bm25: -1)
        let ranked = Ranker().rank([a, b], terms: ["text"], phrases: [])
        XCTAssertEqual(ranked.map(\.id), [3, 7])
    }

    func testRankerWithNoTermsKeepsOrder() {
        let a = passage(1, "A", "alpha", bm25: -1)
        let b = passage(2, "B", "beta", bm25: -2)
        XCTAssertEqual(Ranker().rank([a, b], terms: [], phrases: []).map(\.id), [1, 2])
    }

    func testDedupeDropsNearDuplicates() {
        let text = "Antibiotic resistance spreads through plasmids and horizontal gene transfer in hospitals."
        let a = passage(1, "Antibiotic resistance", text)
        let b = passage(2, "Antibiotic resistance", text + " Extra.")
        let c = passage(3, "Lithium-ion battery", "Cells store energy by shuttling lithium ions between electrodes.")
        let kept = Ranker().dedupe([a, b, c])
        XCTAssertEqual(kept.map(\.id), [1, 3])
    }

    // MARK: - TokenEstimator

    func testTokenEstimateScalesAndIsPositive() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        let short = TokenEstimator.estimate("A short sentence.")
        let long = TokenEstimator.estimate(String(repeating: "A short sentence. ", count: 20))
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short * 10)
    }

    func testTrimKeepsPrefixWithinBudget() {
        let items = Array(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40)
        let kept = TokenEstimator.trim(items, budget: 60) { $0 }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertLessThan(kept.count, items.count)
        XCTAssertLessThanOrEqual(TokenEstimator.estimate(kept), 60 + TokenEstimator.estimate(items[0]))
    }

    // MARK: - PromptBuilder

    func testGroundedPromptContainsNumberedSourcesAndCitations() {
        let passages = [
            passage(1, "Antibiotic resistance", "Resistance emerges when bacteria survive antibiotic exposure."),
            passage(2, "Plasmid", "Plasmids move genes between bacteria.")
        ]
        let built = PromptBuilder(style: .grounded).build(question: "why resistance", passages: passages)
        XCTAssertEqual(built.citations.count, 2)
        XCTAssertEqual(built.citations.first?.index, 1)
        let user = built.messages.last?.content ?? ""
        XCTAssertTrue(user.contains("[1] Antibiotic resistance"))
        XCTAssertTrue(user.contains("Question: why resistance"))
        XCTAssertEqual(built.messages.first?.role, "system")
        XCTAssertTrue(built.messages.first?.content.contains("offline") ?? false)
    }

    func testGroundedPromptFallsBackToPlainWhenNoPassages() {
        let built = PromptBuilder(style: .grounded).build(question: "what is entropy", passages: [])
        XCTAssertTrue(built.citations.isEmpty)
        XCTAssertTrue((built.messages.last?.content ?? "").hasPrefix("Question:"))
    }

    func testPromptRespectsTinyBudget() {
        let passages = (1...20).map { passage($0, "Doc \($0)", String(repeating: "detail ", count: 400)) }
        let built = PromptBuilder(style: .grounded, maxContextTokens: 1200, reserveForAnswer: 400).build(
            question: "compare many things", passages: passages)
        XCTAssertLessThan(built.usedPassages.count, passages.count)
        XCTAssertTrue(built.trimmed)
        XCTAssertLessThan(built.estimatedTokens, 1200)
    }

    func testHistoryIsTruncatedToFourTurns() {
        let history = (0..<10).map { PromptBuilder.ChatMessage(role: "user", content: "turn \($0)") }
        let built = PromptBuilder(style: .plain).build(question: "q", passages: [], history: history)
        XCTAssertEqual(built.messages.count, 6) // system + 4 history + user
    }
}
