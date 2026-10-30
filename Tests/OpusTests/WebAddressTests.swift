import XCTest
@testable import OpusArtifactsKit

/// A web address written without its scheme, as Claude Code prints one, opens
/// over https; file names and real links are left to the other handlers.
final class WebAddressTests: XCTestCase {
    func testAnAddressWithAPathOpensOverHttpsWithoutTheSentenceDot() {
        let line = "La version de démo est en ligne sur demo.example.pro/essai."
        XCTAssertEqual(WebAddress.at(line: line, clickColumn: 42), URL(string: "https://demo.example.pro/essai"))
    }

    func testADomainAloneOpensWhenItsEndingIsAWebOne() {
        XCTAssertEqual(WebAddress.at(line: "voir (example.com), puis", clickColumn: 8),
                       URL(string: "https://example.com"))
        XCTAssertEqual(WebAddress.at(line: "le site www.example.studio", clickColumn: 12),
                       URL(string: "https://www.example.studio"))
    }

    func testAFileNameIsNotAnAddress() {
        for (line, col) in [("lire notes.txt", 7), ("package.json", 3), ("README.md", 2),
                            ("Opus.app/Contents/Info.plist", 3), ("src/Foo.swift", 6), ("v1.2/notes", 1)] {
            XCTAssertNil(WebAddress.at(line: line, clickColumn: col), line)
        }
    }

    func testALinkWithItsSchemeOrAnEmailIsLeftAlone() {
        XCTAssertNil(WebAddress.at(line: "https://example.com/a", clickColumn: 10))
        XCTAssertNil(WebAddress.at(line: "écrire à contact@example.com", clickColumn: 15))
    }

    func testAClickOnASpaceNamesNothing() {
        XCTAssertNil(WebAddress.at(line: "sur example.com", clickColumn: 3))
    }
}
