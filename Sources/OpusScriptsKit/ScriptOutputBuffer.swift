import Foundation

/// What a script has printed so far, bounded.
///
/// A background script left running for days would otherwise grow Opus's
/// memory without limit. The tail is what the user is watching, so the head
/// is what gets dropped — and `truncated` says so, because silently losing
/// output would misrepresent the run.
public struct ScriptOutputBuffer: Equatable, Sendable {
    /// 256 KB of text. Large enough that no ordinary script run is clipped,
    /// small enough that a runaway loop costs nothing worth noticing.
    public static let defaultLimit = 256 * 1024

    public private(set) var text: String = ""
    public private(set) var truncated = false
    private let limit: Int

    public init(limit: Int = ScriptOutputBuffer.defaultLimit) {
        self.limit = max(1, limit)
    }

    public mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        guard text.count > limit else { return }
        text = String(text.suffix(limit))
        truncated = true
    }

    public mutating func clear() {
        text = ""
        // Reset too: a fresh run must not inherit the previous run's warning.
        truncated = false
    }

    /// Removes ANSI escape sequences and turns progress-bar carriage returns
    /// into newlines.
    ///
    /// The panel renders plain text, so a coloured `\u{1B}[0;32mOK\u{1B}[0m`
    /// would otherwise display its escape bytes as literal garbage. Carriage
    /// returns become newlines rather than vanishing: a progress bar that
    /// rewrites one line thirty times is thirty lines here, which is honest,
    /// where dropping the CR would splice them into one unreadable line.
    public static func stripAnsi(_ input: String) -> String {
        guard input.unicodeScalars.contains("\u{1B}") || input.unicodeScalars.contains("\r") else {
            return input
        }

        // Scalars, not Characters. Swift folds "\r\n" into a SINGLE Character,
        // so a `== "\r"` test never fires on a CRLF pair and the raw bytes
        // survive into the output. Iterating scalars sees the two separately,
        // which is the only way this can treat them as one line break.
        var out = String.UnicodeScalarView()
        out.reserveCapacity(input.unicodeScalars.count)
        var iterator = input.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        while let scalar = pending ?? iterator.next() {
            pending = nil

            if scalar == "\u{1B}" {
                // An escape sequence. CSI (ESC [) runs until a byte in @-~;
                // anything else is a two-scalar sequence. A lone ESC at the end
                // of the chunk simply disappears rather than crashing — real
                // output gets split across reads, and half a sequence is not
                // worth preserving.
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let terminator = iterator.next() {
                        if ("\u{40}"..."\u{7E}").contains(terminator) { break }
                    }
                }
                continue
            }

            guard scalar == "\r" else {
                out.append(scalar)
                continue
            }

            // CRLF is one line break, not two. Consume the LF here so the pair
            // does not become a blank line; anything else is put back.
            out.append("\n")
            if let next = iterator.next(), next != "\n" { pending = next }
        }
        return String(out)
    }
}
