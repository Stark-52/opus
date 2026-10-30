import XCTest
@testable import Opus

/// Cmd+click on a path: a folder opens in the Finder, a file in the editor
/// at its line.
final class CommandClickTargetTests: XCTestCase {
    func testAFolderOpensInTheFinder() {
        XCTAssertEqual(TerminalContainerView.clickTarget(path: "/Users/a/Desktop/rendu-validation", line: nil, isDirectory: true),
                       .finder(URL(fileURLWithPath: "/Users/a/Desktop/rendu-validation")))
    }

    func testAFileOpensInTheEditorAtItsLine() {
        XCTAssertEqual(TerminalContainerView.clickTarget(path: "/r/main.swift", line: 12, isDirectory: false),
                       .editor(path: "/r/main.swift", line: 12))
    }
}
