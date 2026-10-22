import XCTest
@testable import OfflineResearchCore

final class TextAndQueryTests: XCTestCase {

    func testFoldStripsDiacriticsAndCase() {
        XCTAssertEqual(TextNormalizer.fold("Café ÉCLAIR"), "cafe eclair")
    }

    func testRawTermsSplitsIdentifiersAndCamelCase() {
        let terms = TextNormalizer.rawTerms("TCP/IP, retrievalAugmentedGeneration and full-text search")
        XCTAssertTrue(terms.contains("tcp"), "got \(terms)")
        XCTAssertTrue(terms.contains("ip"))
        XCTAssertTrue(terms.contains("retrieval"))
        XCTAssertTrue(terms.contains("augmented"))
        XCTAssertTrue(terms.contains("generation"))
        XCTAssertTrue(terms.contains("full"))
        XCTAssertTrue(terms.contains("text"))
    }

    func testQueryTokensDropStopwordsAndKeepIntent() {
        let tokens = TextNormalizer.queryTokens("How does antibiotic resistance spread?")
        XCTAssertTrue(tokens.contains("antibiotic"))
        XCTAssertTrue(tokens.contains("resistance"))
        XCTAssertTrue(tokens.contains("spread"))
        XCTAssertFalse(tokens.contains("does"))
        XCTAssertFalse(tokens.contains("how"), "intent words are kept, but 'how' is a stopword")
    }

    func testIntentWordsSurviveNormalisation() {
        let tokens = TextNormalizer.queryTokens("why is a heat pump better")
        XCTAssertTrue(tokens.contains("better"), "intent terms are kept: got \(tokens)")
        XCTAssertTrue(tokens.contains("heat"))
        XCTAssertFalse(tokens.contains("why"), "'why' is a stopword: too common to retrieve on")
    }

    func testStemIsConservativeAndIdempotent() {
        XCTAssertEqual(TextNormalizer.stem("batteries"), "battery")
        XCTAssertEqual(TextNormalizer.stem("genes"), "gene")
        XCTAssertEqual(TextNormalizer.stem("running"), "runn")
        XCTAssertEqual(TextNormalizer.stem("filter"), "filter")
        XCTAssertEqual(TextNormalizer.stem("class"), "class")
        XCTAssertEqual(TextNormalizer.stem("gas"), "gas")
        for word in ["resistance", "batteries", "running", "genes", "class", "gas", "plasmid"] {
            let once = TextNormalizer.stem(word)
            XCTAssertEqual(TextNormalizer.stem(once), once, "stem not stable for \(word)")
        }
    }

    func testSentenceSplitHandlesAbbreviations() {
        let text = "Resistance spreads via plasmids, e.g. in hospitals. It is a major problem! Does it stop?"
        let sentences = TextNormalizer.sentences(text)
        XCTAssertEqual(sentences.count, 3, "got \(sentences)")
        XCTAssertTrue(sentences[0].contains("e.g. in hospitals"))
    }

    func testSentenceSplitKeepsDecimalsAndTrailingText() {
        let sentences = TextNormalizer.sentences("Efficiency reached 22.5 percent. Costs fell.")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].contains("22.5"))
    }

    // MARK: - QueryBuilder

    func testQueryBuilderEmitsQuotedPrefixVariants() {
        let expression = QueryBuilder().build("what is a kalman filter").primary
        XCTAssertEqual(expression, "\"kalman\"* OR \"filter\"*")
    }

    func testQueryBuilderEmitsBothRawAndStemmedVariants() {
        let expression = QueryBuilder().build("batteries").primary
        XCTAssertTrue(expression.contains("\"batteries\"*"), expression)
        XCTAssertTrue(expression.contains("\"battery\"*"), expression)
    }

    func testQueryBuilderNeutralisesFtsSyntax() {
        let hostile = "NEAR(secret) OR * -- \"drop\""
        let expression = QueryBuilder().build(hostile)
        XCTAssertFalse(expression.primary.contains("NEAR("))
        XCTAssertFalse(expression.primary.contains("OR *"))
        for part in expression.primary.components(separatedBy: " OR ") {
            let body = part.hasSuffix("*") ? String(part.dropLast()) : part
            XCTAssertTrue(body.hasPrefix("\"") && body.hasSuffix("\""), "unquoted term in \(part)")
            XCTAssertEqual(body.filter { $0 == "\"" }.count, 2, "unbalanced quotes in \(part)")
        }
    }

    func testQueryBuilderHandlesEmptyAndPunctuation() {
        let builder = QueryBuilder()
        XCTAssertEqual(builder.build("").primary, "")
        XCTAssertEqual(builder.build("   ?!  ").primary, "")
        XCTAssertTrue(builder.build("").isEmpty)
    }

    func testQueryBuilderCapsTerms() {
        let builder = QueryBuilder(maxTerms: 3)
        let expression = builder.build("alpha beta gamma delta epsilon zeta")
        XCTAssertEqual(expression.tokens.count, 3)
        XCTAssertEqual(expression.terms.count, 3)
    }

    func testPhrasesSkipQuestionScaffolding() {
        let phrases = QueryBuilder.phrases(from: "what is the greenhouse effect", limit: 3)
        XCTAssertFalse(phrases.contains("what is"))
        XCTAssertTrue(phrases.contains("greenhouse effect"), "got \(phrases)")
    }
}
