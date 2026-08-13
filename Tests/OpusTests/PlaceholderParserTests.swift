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

    func testSubstituteReplacesEveryOccurrence() {
        let cmd = "A={{secret:alpha}} B={{secret:alpha}}"
        let out = PlaceholderParser.substitute(cmd, values: ["alpha": "V"])
        XCTAssertEqual(out, "A=V B=V")
    }

    func testSubstituteLeavesUnknownPlaceholdersAlone() {
        // hook-pre refuses before ever calling this with a missing name, but
        // the function must not invent an empty string if it ever happens.
        let out = PlaceholderParser.substitute("{{secret:known}} {{secret:other}}", values: ["known": "V"])
        XCTAssertEqual(out, "V {{secret:other}}")
    }

    func testSubstituteDoesNotRescanInsertedValues() {
        // A value that itself looks like a placeholder must NOT be expanded
        // a second time. One pass, left to right.
        let out = PlaceholderParser.substitute("{{secret:a}}", values: ["a": "{{secret:b}}", "b": "LEAKED"])
        XCTAssertEqual(out, "{{secret:b}}")
    }

    func testSubstituteOnTextWithNoPlaceholdersIsIdentity() {
        XCTAssertEqual(PlaceholderParser.substitute("ls -la", values: ["a": "V"]), "ls -la")
    }
}
