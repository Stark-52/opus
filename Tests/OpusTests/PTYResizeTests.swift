// PTYResizeTests — a resize has to reach the process in the pty, or Claude
// Code keeps drawing for the old width into a terminal of the new one.

import XCTest
import SwiftTerm
@testable import Opus

final class PTYResizeTests: XCTestCase {
    private final class Collector: LocalProcessDelegate {
        var output = ""
        let exited: XCTestExpectation
        init(exited: XCTestExpectation) { self.exited = exited }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) { exited.fulfill() }
        func dataReceived(slice: ArraySlice<UInt8>) { output += String(decoding: slice, as: UTF8.self) }
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    }

    func testTheProcessSeesTheNewSize() {
        let collector = Collector(exited: expectation(description: "the process exits"))
        let process = LocalProcess(delegate: collector, dispatchQueue: .main)
        process.startProcess(executable: "/bin/sh", args: ["-c", "sleep 0.5; stty size"])

        process.resizePTY(cols: 77, rows: 22)

        waitForExpectations(timeout: 5)
        XCTAssertTrue(collector.output.contains("22 77"), "stty saw: \(collector.output)")
    }
}
