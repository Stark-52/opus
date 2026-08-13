// ShellQuoteScanner — a LOAD-BEARING SECURITY CONTROL, tracking POSIX shell
// quoting (and, since the heredoc finding below, heredoc-body) state across
// a command string, so a caller can ask "what context does position I sit
// in, and is there a live, unconsumed backslash sitting right before it?"
//
// This is deliberately NOT a full shell parser — see the three-way quote
// distinction below, which is all CommandSubstitutionRewriter needs to
// decide how a `{{secret:name}}` placeholder must be rewritten. Every gap
// between this model and real POSIX shell grammar is not a cosmetic
// mismatch: it is a silent "literal string sent as if it were the
// credential" bug, because a placeholder this scanner misclassifies gets
// spliced with the wrong syntax (or none) and the shell either never
// expands it or expands it somewhere unintended. The heredoc finding is the
// proof: this scanner used to know nothing about `<<`/`<<-` redirection, so
// a heredoc body read as plain "outside quotes" — safe-looking — while a
// real shell treats that body as literal text no `$(...)` splice can safely
// enter. Any future extension of this scanner (a new operator, a new
// quoting form) must be held to the same standard: reason about it, then
// PROVE it against a real `/bin/bash`, the way CommandSubstitutionRewriterTests
// does — reasoning alone is what missed both this and the pending-escape bug.
//
// `{{secret:name}}` placeholder — the rewriter this file supports — cares
// about three quote regions, which is why only three are modelled:
//
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
//
// Heredoc bodies (`<<WORD` / `<<-WORD`, quoted or not — but NOT `<<<`, a
// here-string, which is ordinary shell text and needs no special handling
// here): the body text is never subject to $(...) expansion the way this
// scanner's three quote regions are — a QUOTED delimiter (`<<'EOF'` or
// `<<"EOF"`) disables ALL expansion inside the body, and even an UNQUOTED
// delimiter (`<<EOF`) does not make a bare `$(...)` splice safe, because
// this rewriter also adds its OWN surrounding double quotes in some
// contexts, and those added quote characters would land as literal text
// inside the body rather than as syntax. So every position inside a
// heredoc body is tracked as its own state, independent of the outside/
// single/double distinction above, and the rewriter refuses there
// unconditionally rather than trying to pick a shape that composes safely
// with a context this scanner does not fully model.
//
// Only a heredoc operator recognised OUTSIDE any quoted region opens a
// heredoc body: `<<` typed inside quotes is just literal text, not an
// operator, exactly like every other shell metacharacter this scanner
// already only recognises in the outside state.

import Foundation

enum ShellQuoteContext: Equatable {
    case outside
    case singleQuoted
    case doubleQuoted
}

/// The full state of the scanner at a position: which quoted region (if
/// any) surrounds it, whether it is the target of a still-live, unconsumed
/// backslash immediately before it, and whether it sits inside the BODY of
/// a heredoc (between the `<<WORD` line and the line holding the bare
/// delimiter).
struct ShellPosition: Equatable {
    let quoteContext: ShellQuoteContext
    let pendingEscape: Bool
    let insideHeredocBody: Bool
}

enum ShellQuoteScanner {
    /// A heredoc queued by a `<<WORD` / `<<-WORD` operator seen on the
    /// current header line, waiting for that line's closing newline to
    /// actually start consuming its body. `stripLeadingTabs` records
    /// whether the operator was the `<<-` form, which strips leading tabs
    /// from both the body lines and the terminator line when matching it —
    /// `<<` (no dash) requires the terminator to match with NO leading
    /// whitespace at all.
    private struct PendingHeredoc {
        let delimiter: String
        let stripLeadingTabs: Bool
    }

    /// The full position state AT `index`: produced by consuming every
    /// character strictly before `index`. That is exactly the state a
    /// token starting at `index` (such as a placeholder match) sits in —
    /// the character at `index` itself has not been looked at yet.
    static func position(in text: String, at index: String.Index) -> ShellPosition {
        var state = ShellQuoteContext.outside
        var escapeNext = false

        // Heredocs queued on the CURRENT header line, in the order their
        // `<<`/`<<-` operator appeared — POSIX consumes their bodies in
        // that same order, one after another, once the header line ends.
        var queuedHeredocs: [PendingHeredoc] = []
        // The heredoc body currently being consumed, if any.
        var activeHeredoc: PendingHeredoc?
        // The current physical line, accumulated only while `activeHeredoc`
        // is set — this is what gets compared against the delimiter the
        // instant a newline ends the line.
        var currentLine = ""

        var i = text.startIndex
        while i < index {
            let c = text[i]

            if let heredoc = activeHeredoc {
                if c == "\n" {
                    let candidate = heredoc.stripLeadingTabs
                        ? String(currentLine.drop(while: { $0 == "\t" }))
                        : currentLine
                    if candidate == heredoc.delimiter {
                        activeHeredoc = queuedHeredocs.isEmpty ? nil : queuedHeredocs.removeFirst()
                    }
                    currentLine = ""
                } else {
                    currentLine.append(c)
                }
                i = text.index(after: i)
                continue
            }

            if escapeNext {
                escapeNext = false
                i = text.index(after: i)
                continue
            }

            switch state {
            case .singleQuoted:
                if c == "'" { state = .outside }
                // No other character has any special meaning in here,
                // deliberately including backslash — escapeNext is never
                // set while in this state, so pendingEscape can never come
                // back true out of a single-quoted region.
                i = text.index(after: i)
            case .doubleQuoted:
                if c == "\\" {
                    escapeNext = true
                } else if c == "\"" {
                    state = .outside
                }
                i = text.index(after: i)
            case .outside:
                if c == "\n" {
                    // The header line (if any heredoc operator appeared on
                    // it) ends here — its body starts on the very next
                    // character.
                    if !queuedHeredocs.isEmpty {
                        activeHeredoc = queuedHeredocs.removeFirst()
                        currentLine = ""
                    }
                    i = text.index(after: i)
                } else if c == "<" {
                    if let (heredoc, afterWord) = matchHeredocOperator(in: text, at: i) {
                        queuedHeredocs.append(heredoc)
                        i = afterWord
                    } else {
                        // Not a heredoc operator: either a single `<`
                        // redirection, or a run of three or more (a
                        // here-string `<<<`, or beyond). Consume the WHOLE
                        // run in one step rather than one character —
                        // advancing by only one would leave `i` sitting on
                        // the run's own second character, and re-examining
                        // `<<` starting THERE (now followed by whatever
                        // comes after the run, not by another `<`) would
                        // misread a `<<<` as a fresh heredoc operator.
                        var run = i
                        while run < text.endIndex, text[run] == "<" { run = text.index(after: run) }
                        i = run
                    }
                } else if c == "\\" {
                    escapeNext = true
                    i = text.index(after: i)
                } else if c == "'" {
                    state = .singleQuoted
                    i = text.index(after: i)
                } else if c == "\"" {
                    state = .doubleQuoted
                    i = text.index(after: i)
                } else {
                    i = text.index(after: i)
                }
            }
        }
        return ShellPosition(
            quoteContext: state,
            pendingEscape: escapeNext,
            insideHeredocBody: activeHeredoc != nil
        )
    }

    /// Recognises a heredoc operator starting exactly at `i` (which holds
    /// `<`): `<<` or `<<-`, deliberately NOT `<<<` (a here-string, which is
    /// ordinary shell text as far as this scanner is concerned — three or
    /// more consecutive `<` never match here). On a match, parses the
    /// delimiter word that follows (quoted with `'` or `"`, or a bare
    /// whitespace-terminated run) and returns it along with the index right
    /// after that word — still on the same header line, which the caller
    /// keeps scanning normally.
    private static func matchHeredocOperator(
        in text: String, at i: String.Index
    ) -> (PendingHeredoc, String.Index)? {
        let afterFirst = text.index(after: i)
        guard afterFirst < text.endIndex, text[afterFirst] == "<" else { return nil }
        let afterSecond = text.index(after: afterFirst)
        // A third consecutive `<` makes this `<<<` (here-string) or beyond,
        // never a heredoc — leave it alone entirely.
        if afterSecond < text.endIndex, text[afterSecond] == "<" { return nil }

        var cursor = afterSecond
        var stripLeadingTabs = false
        if cursor < text.endIndex, text[cursor] == "-" {
            stripLeadingTabs = true
            cursor = text.index(after: cursor)
        }
        // Blanks (not newlines) between the operator and its delimiter word
        // are allowed and skipped: `<< EOF` and `<<EOF` are equivalent.
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }

        let (delimiter, afterWord) = heredocDelimiterWord(in: text, from: cursor)
        return (PendingHeredoc(delimiter: delimiter, stripLeadingTabs: stripLeadingTabs), afterWord)
    }

    /// The delimiter word itself: quoted forms (`'EOF'`, `"EOF"`) contribute
    /// only their contents, matching what a real terminator line contains
    /// (never the quote characters). An unquoted word ends at the first
    /// whitespace (including a newline, so `<<EOF` with nothing after the
    /// word on the header line still terminates the word correctly) and a
    /// backslash inside it escapes the next character without surviving
    /// into the delimiter text — `<<\EOF` still terminates on a bare `EOF`
    /// line, same as real bash.
    private static func heredocDelimiterWord(
        in text: String, from start: String.Index
    ) -> (String, String.Index) {
        guard start < text.endIndex else { return ("", start) }
        let quote = text[start]
        if quote == "'" || quote == "\"" {
            var idx = text.index(after: start)
            var word = ""
            while idx < text.endIndex, text[idx] != quote {
                word.append(text[idx])
                idx = text.index(after: idx)
            }
            if idx < text.endIndex { idx = text.index(after: idx) } // the closing quote
            return (word, idx)
        }

        var idx = start
        var word = ""
        while idx < text.endIndex, !text[idx].isWhitespace {
            if text[idx] == "\\" {
                idx = text.index(after: idx)
                guard idx < text.endIndex else { break }
            }
            word.append(text[idx])
            idx = text.index(after: idx)
        }
        return (word, idx)
    }
}
