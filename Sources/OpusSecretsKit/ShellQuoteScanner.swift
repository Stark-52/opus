// ShellQuoteScanner — tracks POSIX shell quoting state across a command
// string, so a caller can ask "what quote context does position I sit in,
// and is there a live, unconsumed backslash sitting right before it?"
//
// This is the piece CommandSubstitutionRewriter leans on to decide how a
// `{{secret:name}}` placeholder must be rewritten: `$(...)` behaves
// differently depending on whether it lands outside any quotes, inside
// double quotes, or inside single quotes, and those three are the only
// quote distinction that matters here — this is deliberately not a full
// shell tokenizer.
//
// The pending-escape flag exists for a reason that is easy to miss by
// reasoning about quoting alone rather than running the result: a
// placeholder can sit at a position whose QUOTE context is perfectly safe
// (outside, or inside double quotes) while still being the TARGET of a
// backslash immediately before it, with zero characters in between
// (`\{{secret:k}}`). Splicing new syntax onto a live pending escape is not
// safe in EITHER of those two contexts — see CommandSubstitutionRewriter —
// so the rewriter needs to know about it, not just the quote state.
//
// Rules, precise on the point that actually differs between the two quote
// kinds:
//   outside quotes:        a backslash escapes the next character,
//                           UNCONDITIONALLY (POSIX: this is a blanket rule
//                           for unquoted text). That character is consumed
//                           and cannot itself open or close a quoted region
//                           (so `\"` does not open a double-quoted region),
//                           and it is "pending" — about to be escaped — for
//                           as long as the scan has not yet passed it.
//   inside double quotes:  a backslash escapes the next character too, so
//                           `\"` does not close the region it is inside.
//                           (POSIX actually restricts this to $ ` " \ and
//                           newline; treating it as unconditional here is a
//                           deliberate simplification that only affects
//                           which character gets swallowed, never whether a
//                           `"` is correctly seen as a real close — the
//                           only characters this scanner cares about, `"`
//                           and `\` themselves, are exactly the ones POSIX
//                           always escapes here too.)
//   inside single quotes:  NOTHING is special, not even backslash. Only a
//                           literal closing `'` ends the region. This means
//                           a run like `'\'` is a COMPLETE, closed
//                           single-quoted region containing one backslash —
//                           not an unterminated quote — because the
//                           backslash inside it never escapes the `'` that
//                           follows, and it can never leave a pending
//                           escape either.
//
// A run of backslashes cancels itself out in pairs: `\\` immediately before
// a position leaves nothing pending (the first backslash's target IS the
// second backslash), `\\\` (three) leaves the third one pending, and so on
// — ordinary POSIX backslash-pair parity, which falls out of the same
// escapeNext bookkeeping used for quote tracking.

import Foundation

enum ShellQuoteContext: Equatable {
    case outside
    case singleQuoted
    case doubleQuoted
}

/// The full state of the scanner at a position: which quoted region (if
/// any) surrounds it, and whether it is the target of a still-live,
/// unconsumed backslash immediately before it.
struct ShellPosition: Equatable {
    let quoteContext: ShellQuoteContext
    let pendingEscape: Bool
}

enum ShellQuoteScanner {
    /// The full position state AT `index`: produced by consuming every
    /// character strictly before `index`. That is exactly the state a
    /// token starting at `index` (such as a placeholder match) sits in —
    /// the character at `index` itself has not been looked at yet.
    static func position(in text: String, at index: String.Index) -> ShellPosition {
        var state = ShellQuoteContext.outside
        var escapeNext = false
        var i = text.startIndex
        while i < index {
            let c = text[i]
            i = text.index(after: i)

            if escapeNext {
                escapeNext = false
                continue
            }

            switch state {
            case .singleQuoted:
                if c == "'" { state = .outside }
                // No other character has any special meaning in here,
                // deliberately including backslash — escapeNext is never
                // set while in this state, so pendingEscape can never come
                // back true out of a single-quoted region.
            case .doubleQuoted:
                if c == "\\" {
                    escapeNext = true
                } else if c == "\"" {
                    state = .outside
                }
            case .outside:
                if c == "\\" {
                    escapeNext = true
                } else if c == "'" {
                    state = .singleQuoted
                } else if c == "\"" {
                    state = .doubleQuoted
                }
            }
        }
        return ShellPosition(quoteContext: state, pendingEscape: escapeNext)
    }

    /// Convenience for callers that only need the quote context (e.g. tests
    /// exercising the state machine's three-way classification in
    /// isolation). Same single traversal as `position(in:at:)`.
    static func context(in text: String, at index: String.Index) -> ShellQuoteContext {
        position(in: text, at: index).quoteContext
    }
}
