// CommandSubstitutionRewriter — turns {{secret:name}} into a shell command
// substitution instead of into the value.
//
// Why: Claude Code writes a hook's own stdout into the session .jsonl as a
// `hook_success` attachment, UNCONDITIONALLY — `suppressOutput: true` only
// hides it from the Ctrl-R transcript view, not from the file on disk.
// hook-pre answers PreToolUse by writing the (formerly) substituted command
// to stdout, so a value substituted there landed on disk every time it was
// used. Verified end to end by a canary test: a disposable secret turned up
// in the transcript file.
//
// The fix: rewrite the placeholder into a command substitution that the
// SHELL resolves at execution time, so the hook's own stdout — and
// therefore the transcript — never contains a value, only the secret's
// NAME and a path to `opus-secrets get`. This is also why HookRunner no
// longer calls `store.value(for:)` at all: the value never needs to enter
// this process.
//
//     Claude writes:      curl -H "Auth: Bearer {{secret:resend}}"
//     rewritten to:       curl -H "Auth: Bearer $(/abs/path/opus-secrets get resend)"
//     the shell resolves: at execution, in the child process that runs the
//                         command — never in the hook.
//
// Quoting determines the exact shape spliced in, via ShellQuoteScanner:
//
//   outside any quotes → "$(path get name)"   quoted by US. Unquoted
//                         command substitution undergoes word splitting, so
//                         a value containing a space would be torn into
//                         several arguments — and the deposit-time
//                         hostility check (SecretExtractor.isShellHostile)
//                         flags quotes/backticks/backslashes/dollars/
//                         newlines but NOT spaces, so an unquoted splice is
//                         a real, reachable break, not a hypothetical one.
//
//   inside double quotes → $(path get name)   bare. It is already inside
//                         the surrounding double quotes, which already
//                         suppress word splitting; adding a second pair
//                         would nest incorrectly.
//
//   inside single quotes → REFUSED, for the whole command. `$(...)` is not
//                         special inside '...' — POSIX single quotes
//                         preserve the literal value of every character —
//                         so splicing it in would send the literal text
//                         "$(...get name)" to a provider AS IF it were the
//                         credential. Not hypothetical: the project's own
//                         documentation examples wrote this pattern with
//                         single quotes.
import Foundation

enum CommandSubstitutionRewrite {
    case rewritten(String)
    case refusedInsideSingleQuotes(name: String)
}

enum CommandSubstitutionRewriter {
    // Same pattern PlaceholderParser uses, kept as a private copy here
    // rather than a shared dependency: this type needs the match ranges to
    // feed ShellQuoteScanner, which is a different job from
    // PlaceholderParser's own (substituting a resolved VALUE), and the two
    // must not become coupled just because they currently share a regex.
    private static let regex = try! NSRegularExpression(
        pattern: "\\{\\{secret:(\(SecretName.grammar))\\}\\}"
    )

    /// Single left-to-right pass over the matches in the ORIGINAL string,
    /// same discipline as PlaceholderParser.substitute: it does not rescan
    /// what it just inserted, so a rewritten `$(...)` cannot itself be
    /// mistaken for a second placeholder.
    static func rewrite(_ command: String, binaryPath: String) -> CommandSubstitutionRewrite {
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = regex.matches(in: command, options: [], range: range)

        var out = ""
        var cursor = command.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: command),
                  let nameRange = Range(match.range(at: 1), in: command)
            else { continue }

            let name = String(command[nameRange])
            let context = ShellQuoteScanner.context(in: command, at: whole.lowerBound)
            // $(...) does not expand inside single quotes at all, so there
            // is no safe rewrite to fall back to here — the whole command
            // must be refused rather than let the literal text through.
            guard context != .singleQuoted else {
                return .refusedInsideSingleQuotes(name: name)
            }

            let substitution = "$(\(shellQuote(binaryPath)) get \(name))"
            let replacement = context == .doubleQuoted ? substitution : "\"\(substitution)\""

            out += command[cursor..<whole.lowerBound]
            out += replacement
            cursor = whole.upperBound
        }
        out += command[cursor...]
        return .rewritten(out)
    }

    /// Single-quote a POSIX path so it survives `sh -c` verbatim. Nth copy
    /// of this idiom in the repo, deliberately: it is tiny, has one call
    /// site here, and is not worth a cross-file dependency (same reasoning
    /// recorded at its other copies in HookSettingsWriter,
    /// TerminalContainerView and ClaudeSettingsMerger).
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
