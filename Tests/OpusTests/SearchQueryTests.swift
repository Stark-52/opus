// SearchQueryTests — the one way every Opus search box matches.
//
// The secrets panel used to need the name typed as stored: dashes included,
// words in their order ("acme-mongodb-uri"). A search box should find
// it from "mongo acme" as well.

import XCTest
@testable import OpusSearchKit

final class SearchQueryTests: XCTestCase {
    private let secret = "acme-mongodb-uri-dev"

    func testWordsMatchInAnyOrderWithoutTheDashes() {
        XCTAssertTrue(SearchQuery("mongo acme").matches(secret))
        XCTAssertTrue(SearchQuery("dev uri").matches(secret))
    }

    func testDashesUnderscoresAndDotsCountAsSpaces() {
        XCTAssertTrue(SearchQuery("mongodb-uri").matches("ACME_MONGODB_URI"))
        XCTAssertTrue(SearchQuery("uri.dev").matches(secret))
    }

    func testAWordMayRunOverASeparatorLeftOut() {
        XCTAssertTrue(SearchQuery("mongodburi").matches(secret))
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertTrue(SearchQuery("MONGO").matches(secret))
        XCTAssertTrue(SearchQuery("createur").matches("Créateur de cartes"))
        XCTAssertTrue(SearchQuery("créateur").matches("createur-de-cartes"))
    }

    func testEveryWordMustBeFound() {
        XCTAssertFalse(SearchQuery("mongo stripe").matches(secret))
    }

    func testWordsMayComeFromDifferentFields() {
        XCTAssertTrue(SearchQuery("sauvegarde nas").matches("Sauvegarde photos", "vers le NAS"))
    }

    func testABlankQueryIsNotAFilter() {
        XCTAssertTrue(SearchQuery("  - ").isEmpty)
        XCTAssertTrue(SearchQuery("").matches(secret))
    }
}
