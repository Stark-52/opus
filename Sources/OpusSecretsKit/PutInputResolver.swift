// PutInputResolver — decides where `put`'s value comes from and whether
// what came back is usable, kept apart from the code that actually reads
// stdin or shells out to pbpaste so the decision itself can be unit tested
// with injected readers, without touching a real TTY or the real clipboard.
//
// The rule: an interactive terminal (nothing piped into stdin) reads the
// clipboard, because blocking on a stdin read with no prompt and no
// explanation just hangs. Anything else — a pipe, input redirected from a
// file — reads stdin exactly as before. Only one of the two readers is
// ever invoked for a given call: which one is decided by `isTTY` alone.

import Foundation

public enum PutInputSource: Equatable {
    case stdin
    case clipboard
}

public enum PutInputOutcome: Equatable {
    case value(String, source: PutInputSource)
    case emptyStdin
    case emptyClipboard
}

public enum PutInputResolver {
    /// - Parameters:
    ///   - isTTY: whether standard input is an interactive terminal (i.e.
    ///     nothing is piped in). Mirrors the `isatty` check already used by
    ///     the `get` subcommand.
    ///   - readStdin: reads and decodes stdin. Called only when `isTTY` is
    ///     false.
    ///   - readClipboard: reads the clipboard. Called only when `isTTY` is
    ///     true.
    public static func resolve(
        isTTY: Bool,
        readStdin: () -> String,
        readClipboard: () -> String
    ) -> PutInputOutcome {
        if isTTY {
            let value = readClipboard().trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .emptyClipboard : .value(value, source: .clipboard)
        } else {
            let value = readStdin().trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .emptyStdin : .value(value, source: .stdin)
        }
    }
}
