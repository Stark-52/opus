// ScrollFollowTests — reading back up the conversation while Claude writes.
//
// The bug: scroll up with the wheel, Claude prints one more line, and the
// view jumps back to the bottom. `Terminal.scroll()` only leaves the viewport
// where it is when `Terminal.userScrolling` is set, and up to SwiftTerm 1.13
// nothing ever set it: the view kept a flag of its own by the same name and
// only flipped it inside `scroll(toPosition:)`. From 1.14 `scrollTo(row:)`
// sets the terminal's flag from where the viewport lands, so a scroll that
// ends above the bottom stays put and one that comes back to the bottom
// follows again.
//
// A live AppKit `TerminalView` rather than `HeadlessTerminal`: the flag is
// set by the view's scrolling path (`scrollUp(lines:)` is what the wheel
// calls), which a headless terminal does not have.
import XCTest
import AppKit
import SwiftTerm

final class ScrollFollowTests: XCTestCase {
    private func makeView(lines: Int) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        view.getTerminal().changeScrollback(1_000)
        feed(view, from: 0, count: lines)
        return view
    }

    private func feed(_ view: TerminalView, from start: Int, count: Int) {
        let text = (start..<start + count).map { "line \($0)" }.joined(separator: "\r\n")
        view.feed(text: "\r\n" + text)
    }

    func testAViewScrolledUpStaysPutWhenNewLinesArrive() {
        let view = makeView(lines: 200)
        view.scrollUp(lines: 50)
        let readingAt = view.getTerminal().buffer.yDisp

        feed(view, from: 200, count: 5)

        XCTAssertEqual(view.getTerminal().buffer.yDisp, readingAt)
    }

    func testAViewBackAtTheBottomFollowsNewLinesAgain() {
        let view = makeView(lines: 200)
        view.scrollUp(lines: 50)
        view.scrollDown(lines: 50)
        let bottom = view.getTerminal().buffer.yDisp

        feed(view, from: 200, count: 5)

        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottom + 5)
    }
}
