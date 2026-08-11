// ScrollbackTests — v1.4.1 Fix 5a verification.
//
// The live-smoke report says Cmd+F "only searches the last segment." Two
// suspects: (a) SwiftTerm's scrollback default (500 lines,
// `TerminalOptions.default.scrollback`) silently overriding
// `OpusPreferences.shared.scrollbackLines` (10,000 by default), or (b) the
// find bar's search DIRECTION (fixed separately — see FindBarView.swift /
// TerminalContainerView.searchUpInActivePane). This file empirically checks
// (a): does `Terminal.changeScrollback`, called at the SAME point and in the
// SAME order as `TerminalContainerView.styleTerminal` calls it (immediately
// after construction, before any output is fed), actually widen the
// retained buffer?
//
// Uses SwiftTerm's `HeadlessTerminal` (public, ships in the package itself —
// see SwiftTerm/Sources/SwiftTerm/HeadlessTerminal.swift) rather than a live
// AppKit `TerminalView`: it wraps the exact same `Terminal` class
// `TerminalView.getTerminal()` returns, so there is no separate
// "TerminalView-specific" scrollback code path to worry about diverging —
// confirmed by reading Terminal.swift (`changeScrollback` /
// `Buffer.changeHistorySize`) and CircularList.swift (`maxLength`'s
// didSet): growing `maxLength` reallocates the backing array and copies
// every currently-retained line across, and every later `Buffer.resize`
// recomputes its cap from `getCorrectBufferLength(rows) = rows +
// self.scrollback`, reading the SAME `scrollback` value `changeHistorySize`
// just stored — so an early `changeScrollback` call keeps applying through
// every later resize, not just the very next one.
//
// `Terminal.getLine(row:)` is VIEWPORT-relative (see the doc comment
// TerminalContainerView.resolvePathClick already has on this exact gotcha)
// and can't reach scrollback history at all. `Terminal
// .getScrollInvariantLine(row:)` is the public API that counts from the
// start of the retained buffer instead — used here to read back every line
// still present, oldest first.
import XCTest
import SwiftTerm

final class ScrollbackTests: XCTestCase {
    /// Every currently-retained line, oldest first, as plain strings.
    ///
    /// `getScrollInvariantLine(row:)`'s doc comment says row counts "from
    /// the beginning of the scroll buffer" — which reads like "from 0" but
    /// ISN'T once eviction has happened: `Terminal.scroll()`'s full-buffer
    /// path (`lines.recycle(...)`) increments `buffer.linesTop` on every
    /// evicted line (confirmed by reading Terminal.swift directly — grepping
    /// only for `linesTop =` misses this, it's a `+=`), and
    /// `getScrollInvariantLine` rejects any `row < linesTop`. So "row 0" only
    /// ever resolves once, before the FIRST eviction; after that the valid
    /// window slides forward with `linesTop`, which isn't itself exposed
    /// (Buffer.linesTop is internal to the SwiftTerm module). Scanning a
    /// wide fixed range and collecting every hit (instead of stopping at the
    /// first nil) sidesteps needing to know `linesTop` at all — the valid
    /// window is contiguous, so hits still come out oldest-first.
    private func allRetainedLines(_ terminal: Terminal, scanning upperBound: Int) -> [String] {
        var result: [String] = []
        for row in 0..<upperBound {
            if let line = terminal.getScrollInvariantLine(row: row) {
                result.append(line.translateToString(trimRight: true))
            }
        }
        return result
    }

    /// Numbered marker lines, fixed-width so "LINE00001" can't accidentally
    /// prefix-match "LINE000010" or similar.
    private func feedNumberedLines(_ terminal: Terminal, count: Int) {
        for i in 1...count {
            terminal.feed(text: "LINE\(String(format: "%05d", i))\r\n")
        }
    }

    /// THE VERDICT TEST — mirrors `styleTerminal`'s call site exactly: build
    /// a terminal with SwiftTerm's stock default options (scrollback = 500,
    /// same as an un-styled TerminalView), then IMMEDIATELY call
    /// `changeScrollback(10_000)` before any output is fed — same order as
    /// `t.getTerminal().changeScrollback(OpusPreferences.shared
    /// .scrollbackLines)` in styleTerminal, called right after
    /// `TerminalView(frame:)` construction and before the pane's process
    /// ever starts writing to it. Then feeds 2,000 lines — 4x the old
    /// 500-line cap, comfortably beyond it — and checks whether the
    /// EARLIEST one survived.
    func test_changeScrollbackAtCreationTime_retainsLinesBeyondThe500LineDefault() {
        let host = HeadlessTerminal(options: .default) { _ in }
        host.changeScrollback(10_000)
        feedNumberedLines(host.terminal, count: 2_000)

        let lines = allRetainedLines(host.terminal, scanning: 2_100)
        XCTAssertTrue(
            lines.contains("LINE00001"),
            "with scrollback raised to 10,000 BEFORE any output, the earliest " +
            "of 2,000 fed lines must still be in the buffer — if this fails, " +
            "changeScrollback is NOT effective at this call site and IS the " +
            "root cause of \"only searches the last segment.\""
        )
        XCTAssertTrue(lines.contains("LINE02000"), "the most recent line must always survive")
    }

    /// Control — same 2,000 lines, but scrollback is left at SwiftTerm's
    /// stock 500-line default (`changeScrollback` never called). This MUST
    /// evict the earliest line, or the harness itself (not the app code)
    /// would be too weak to tell a working fix from a broken one, and the
    /// test above would be a false positive no matter what
    /// `changeScrollback` actually does.
    func test_defaultScrollback_evictsLinesBeyondThe500LineCap() {
        let host = HeadlessTerminal(options: .default) { _ in }   // scrollback left at the 500-line default
        feedNumberedLines(host.terminal, count: 2_000)

        let lines = allRetainedLines(host.terminal, scanning: 2_100)
        XCTAssertFalse(
            lines.contains("LINE00001"),
            "the stock 500-line default must NOT retain a line from 2,000 lines back " +
            "— if this fails, the control itself is broken (see the doc comment above)"
        )
        XCTAssertTrue(lines.contains("LINE02000"), "the most recent line must always survive")
    }

    /// Sanity check on `getScrollInvariantLine` itself, independent of
    /// `changeScrollback`: confirms it really does count from the start of
    /// the retained buffer (oldest-first), not the visible viewport — the
    /// property this whole verification leans on.
    func test_getScrollInvariantLine_countsFromStartOfRetainedBuffer_notViewport() {
        let host = HeadlessTerminal(options: .default) { _ in }
        host.terminal.feed(text: "FIRST\r\nSECOND\r\nTHIRD\r\n")

        let lines = allRetainedLines(host.terminal, scanning: 100)
        guard let firstIdx = lines.firstIndex(of: "FIRST"),
              let secondIdx = lines.firstIndex(of: "SECOND"),
              let thirdIdx = lines.firstIndex(of: "THIRD") else {
            return XCTFail("expected FIRST/SECOND/THIRD all present in the retained buffer")
        }
        XCTAssertLessThan(firstIdx, secondIdx)
        XCTAssertLessThan(secondIdx, thirdIdx)
    }
}
