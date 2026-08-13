import XCTest
@testable import OpusSecretsKit

final class PlaceholderParserTests: XCTestCase {
    func testContainsMarkerIsTheFastPathGate() {
        XCTAssertFalse(PlaceholderParser.containsMarker("ls -la"))
        XCTAssertFalse(PlaceholderParser.containsMarker("echo '{{ not a secret }}'"))
        XCTAssertTrue(PlaceholderParser.containsMarker("curl -H 'X: {{secret:k}}'"))
    }

    func testNamesFindsAllOccurrencesInOrder() {
        let cmd = "A={{secret:alpha}} B={{secret:beta}} C={{secret:alpha}}"
        XCTAssertEqual(PlaceholderParser.names(in: cmd), ["alpha", "beta"])
    }

    func testNamesIgnoresPlaceholdersThatViolateTheGrammar() {
        XCTAssertEqual(PlaceholderParser.names(in: "{{secret:UPPER}}"), [])
        XCTAssertEqual(PlaceholderParser.names(in: "{{secret:-leading}}"), [])
        XCTAssertEqual(PlaceholderParser.names(in: "{{secret:has space}}"), [])
        XCTAssertEqual(PlaceholderParser.names(in: "{{secret:}}"), [])
    }

    func testNamesFindsPlaceholdersGluedToSurroundingText() {
        XCTAssertEqual(PlaceholderParser.names(in: "Bearer{{secret:k}}suffix"), ["k"])
    }

    func testNamesAcceptsUnderscoreInName() {
        // The underscore IS in SecretName.grammar. This is the detail the
        // plan got wrong twice, so it gets an assertion rather than trust.
        XCTAssertEqual(PlaceholderParser.names(in: "{{secret:my_key}}"), ["my_key"])
    }
}
