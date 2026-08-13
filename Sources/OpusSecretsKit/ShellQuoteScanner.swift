// ShellQuoteScanner — tracks POSIX shell quoting state across a command
// string, so a caller can ask "what quote context does position I sit in?"
//
// This is the piece CommandSubstitutionRewriter leans on to decide how a
// `{{secret:name}}` placeholder must be rewritten: `$(...)` behaves
// differently depending on whether it lands outside any quotes, inside
// double quotes, or inside single quotes, and those three are the only
// distinction that matters here — this is deliberately not a full shell
// tokenizer.
//
// Rules, precise on the point that actually differs between the two quote
// kinds:
//   outside quotes:        a backslash escapes the next character. That
//                           character is consumed and cannot itself open or
//                           close a quoted region (so `\"` does not open a
//                           double-quoted region).
//   inside double quotes:  same escaping behaviour — a backslash escapes
//                           the next character, so `\"` does not close the
//                           region it is inside.
//   inside single quotes:  NOTHING is special, not even backslash. Only a
//                           literal closing `'` ends the region. This means
//                           a run like `'\'` is a COMPLETE, closed
//                           single-quoted region containing one backslash —
//                           not an unterminated quote — because the
//                           backslash inside it never escapes the `'` that
//                           follows.

import Foundation

enum ShellQuoteContext: Equatable {
    case outside
    case singleQuoted
    case doubleQuoted
}

enum ShellQuoteScanner {
    /// The quoting context in effect AT `index`: the state produced by
    /// consuming every character strictly before `index`. That is exactly
    /// the context a token starting at `index` (such as a placeholder
    /// match) sits in — the character at `index` itself has not been looked
    /// at yet.
    static func context(in text: String, at index: String.Index) -> ShellQuoteContext {
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
                // deliberately including backslash.
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
        return state
    }
}
