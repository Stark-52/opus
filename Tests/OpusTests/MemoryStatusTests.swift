// MemoryStatusTests — the memory-router mod's file, as the rail shows it.

import XCTest
@testable import Opus

final class MemoryStatusTests: XCTestCase {
    func testTheLoadedDomainsAreNamedInTheOrderTheyCame() {
        let data = Data(#"{"domains":["Atelier","Jeu: v.2"]}"#.utf8)
        XCTAssertEqual(MemoryStatus.label(data), "mémoire : Atelier · Jeu: v.2")
    }

    func testNoDomainMeansTheCoreAlone() {
        XCTAssertEqual(MemoryStatus.label(Data(#"{"domains":[]}"#.utf8)), "mémoire : socle")
    }

    func testAMalformedFileShowsNothing() {
        XCTAssertNil(MemoryStatus.label(Data("not json".utf8)))
        XCTAssertNil(MemoryStatus.label(Data(#"{"domains":"Atelier"}"#.utf8)))
    }

    func testEachSessionHasItsOwnFile() {
        XCTAssertEqual(MemoryStatus.fileURL(sessionId: "abc").lastPathComponent, "abc.json")
        XCTAssertEqual(MemoryStatus.fileURL(sessionId: "abc").deletingLastPathComponent().lastPathComponent, "memory")
    }

    func testTheRailNamesTheMemoryAfterTheUsage() {
        let windows = [UsageWindow(kind: .fiveHour, percent: 12, resetsAt: Date(timeIntervalSince1970: 0))]
        let both = StatusRailView.trailingText(usage: windows, memory: "mémoire : socle").string
        XCTAssertTrue(both.hasPrefix("│ 5h 12%"), both)
        XCTAssertTrue(both.hasSuffix(" │ mémoire : socle"), both)

        XCTAssertEqual(StatusRailView.trailingText(usage: [], memory: "mémoire : socle").string, "│ mémoire : socle")
        XCTAssertEqual(StatusRailView.trailingText(usage: [], memory: nil).string, "")
    }
}
