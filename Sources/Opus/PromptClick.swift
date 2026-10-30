// PromptClick — a click inside Claude Code's input, turned into the arrow
// keys that walk its cursor there.
//
// A terminal has no text field to click into: Claude Code draws its input
// between two `────` rules, the text starting after "❯ " (continuation rows
// are indented to the same column), and only arrow keys move its cursor.
// On the cursor's own row the click becomes left or right presses, one per
// character between the two (a wide character is one press over two
// cells). On another row of the input it first becomes up or down presses;
// the caller reads the cursor again once Claude Code has redrawn and asks
// for the horizontal part then. Up and down stay inside the input, since
// both rows are between the rules: neither can reach the prompt history.

import Foundation
import SwiftTerm

enum PromptClick {
    struct Cell: Equatable {
        let character: Character
        /// Columns the character takes: 2 for a wide one, then 0 for the
        /// column it covers.
        let width: Int
    }

    enum Plan: Equatable {
        /// Right presses when positive, left presses when negative.
        case horizontal(Int)
        /// Down presses when positive, up presses when negative.
        case vertical(Int)
    }

    /// Where the text starts on every input row: after "❯ " on the first,
    /// after the matching indentation on the others.
    static let textStart = 2

    /// The rows strictly between the rules above and below the cursor, or
    /// nil when the cursor is not inside such a box (a menu, a dialog).
    static func inputRows(_ screen: [[Cell]], cursorRow: Int) -> ClosedRange<Int>? {
        guard screen.indices.contains(cursorRow), !isRule(screen[cursorRow]) else { return nil }
        guard let above = (0..<cursorRow).last(where: { isRule(screen[$0]) }),
              let below = ((cursorRow + 1)..<screen.count).first(where: { isRule(screen[$0]) })
        else { return nil }
        return (above + 1)...(below - 1)
    }

    static func plan(_ screen: [[Cell]], cursor: (x: Int, y: Int), click: (col: Int, row: Int)) -> Plan? {
        guard let rows = inputRows(screen, cursorRow: cursor.y), rows.contains(click.row) else { return nil }

        if click.row != cursor.y {
            return .vertical(click.row - cursor.y)
        }
        let presses = horizontalPresses(screen[cursor.y], from: cursor.x, to: click.col)
        return presses == 0 ? nil : .horizontal(presses)
    }

    /// Characters between two columns of one row, signed. The target is held
    /// inside the text: a click in the margin lands on its first character,
    /// one past the end on the end, since extra presses would wrap onto the
    /// next line.
    static func horizontalPresses(_ row: [Cell], from: Int, to: Int) -> Int {
        let end = max(textStart, (row.lastIndex(where: { $0.character != " " && $0.width > 0 }) ?? textStart - 1) + 1)
        let target = min(max(to, textStart), end)
        let start = min(max(from, 0), row.count)
        let (low, high) = (min(start, target), max(start, target))
        let characters = row[low..<min(high, row.count)].filter { $0.width > 0 }.count
        return target >= start ? characters : -characters
    }

    private static func isRule(_ row: [Cell]) -> Bool {
        let marks = row.map(\.character).filter { $0 != " " }
        return marks.count >= 3 && marks.allSatisfy { $0 == "─" }
    }
}

extension PromptClick {
    /// The rows of a viewport snapshot as cells. A cell nothing was written
    /// to holds NUL (Claude Code skips the gaps between words with cursor
    /// moves), read here as a space so it never counts as text or breaks a
    /// rule.
    static func screen(of snapshot: TerminalContentSnapshot) -> [[Cell]] {
        snapshot.rows.map { row in
            row.cells.map { cell in
                let character = cell.text.first ?? " "
                return Cell(character: character == "\u{0}" ? " " : character, width: cell.width)
            }
        }
    }

    /// The key presses for one step of the walk towards `click`, in the
    /// cursor-key mode the application asked for, and whether the step was
    /// vertical (the caller then asks again once Claude Code has redrawn).
    /// `snapshot` is the viewport, whose first row is the click's row 0.
    static func keys(in snapshot: TerminalContentSnapshot, click: (col: Int, row: Int),
                     allowVertical: Bool) -> (keys: [UInt8], isVertical: Bool)? {
        let app = snapshot.inputState.applicationCursor
        let cursor = (x: snapshot.cursorColumn, y: snapshot.cursorRow - snapshot.capturedRange.lowerBound)
        switch plan(screen(of: snapshot), cursor: cursor, click: click) {
        case .horizontal(let count)?:
            let key = count > 0
                ? (app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
                : (app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
            return (Array(repeating: key, count: abs(count)).flatMap { $0 }, false)
        case .vertical(let count)? where allowVertical:
            let key = count > 0
                ? (app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
                : (app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
            return (Array(repeating: key, count: abs(count)).flatMap { $0 }, true)
        default:
            return nil
        }
    }
}
