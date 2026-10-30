// PTYResize — giving a claude process's pty a new size.

import Foundation
import SwiftTerm

extension LocalProcess {
    /// Sets the pty's window size, then SIGWINCHes the child so it re-reads
    /// the size and redraws.
    func resizePTY(cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        updateWindowSize(&ws)
        if shellPid > 0 { kill(shellPid, SIGWINCH) }
    }
}
