import XCTest
import AppKit
import SwiftTerm
import OpusArtifactsKit
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

/// The rows read off a real terminal, as Claude Code leaves them once it has
/// wrapped a path, resolve to the folder on disk.
final class CommandClickWrappedPathTests: XCTestCase {
    func testAFolderNameWrappedAtItsSpaceOpensFromEitherRow() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("Mes Images/export/2026-10-30"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1600, height: 320))
        let head = "  Elle est dans \(root.path)/Mes"
        XCTAssertLessThan(head.count, view.terminalDimensions.cols, "the first row must not wrap on its own")
        // Claude Code breaks at the space and indents the rest like its paragraph.
        view.feed(text: head + "\r\n  Images/export/2026-10-30/.\r\n")

        let optimal = view.getOptimalFrameSize()
        let cell = (width: optimal.width / CGFloat(view.terminalDimensions.cols),
                    height: optimal.height / CGFloat(view.terminalDimensions.rows))
        for (row, col) in [(1, 8), (0, head.count - 2)] {
            let point = NSPoint(x: (CGFloat(col) + 0.5) * cell.width,
                                y: view.bounds.height - (CGFloat(row) + 0.5) * cell.height)
            let hit = try XCTUnwrap(TerminalContainerView.resolvePathClick(in: view, at: point))
            let found = PathDetector.resolve(rows: hit.rows, clickRow: hit.row, clickColumn: hit.col, cwd: "/",
                                             exists: { fm.fileExists(atPath: $0) })
            XCTAssertEqual(found?.path, root.appendingPathComponent("Mes Images/export/2026-10-30").path,
                           "click on row \(row)")
        }
    }
}
