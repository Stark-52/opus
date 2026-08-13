// HookRunner — the three Claude Code hook modes, as pure Data in / Data?
// out so every branch is unit-testable without spawning a process.
//
// Returning nil means "write nothing and exit 0". That is the normal
// outcome for the overwhelming majority of tool calls, and it is what
// keeps these hooks off the critical path.
//
// Verified against claude 2.1.231:
//   PreToolUse  accepts hookSpecificOutput.updatedInput, which replaces the
//               ENTIRE tool input object and is validated against the
//               tool's input schema. The field is updatedInput. There is no
//               such field as modifiedInput.
//   PostToolUse accepts hookSpecificOutput.updatedToolOutput, which
//               replaces the output before the model sees it, for all
//               tools, and is validated against the tool's output shape.
//
// runPre does NOT resolve secret values, on purpose. It used to: it read
// each requested value and substituted it directly into `command`, and
// that command became `updatedInput.command`, which IS this hook's stdout.
// Because Claude Code writes a hook's stdout into the session .jsonl
// unconditionally (see the `suppressOutput` note on `encode`, below), every
// substitution put the real value on disk. Confirmed by an end-to-end
// canary test with a disposable secret. The fix is
// CommandSubstitutionRewriter: it rewrites the placeholder into a shell
// `$(...)` command substitution that the SHELL resolves later, at
// execution time, in the process that actually runs the command — never in
// this one. So runPre only needs to confirm the name EXISTS
// (`store.names()`), never read what it maps to.

import Foundation

public struct HookRunner {
    private let store: SecretStore
    private let usage: SessionUsage
    private let binaryPath: String

    /// `binaryPath` is what gets embedded in every rewritten `$(...)`
    /// command substitution (see runPre / CommandSubstitutionRewriter). It
    /// defaults to this PROCESS's own absolute path: the hook is always
    /// invoked by absolute path from settings.json (ClaudeSettingsMerger
    /// writes it that way), so `CommandLine.arguments[0]` IS the binary a
    /// rewritten placeholder must shell back out to. Made injectable, with
    /// this default, so tests can assert against a fixed string instead of
    /// a machine- and build-directory-dependent one.
    public init(store: SecretStore, usage: SessionUsage, binaryPath: String = CommandLine.arguments[0]) {
        self.store = store
        self.usage = usage
        self.binaryPath = binaryPath
    }

    // MARK: PreToolUse

    public func runPre(input: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        guard root["tool_name"] as? String == "Bash" else { return nil }
        guard var toolInput = root["tool_input"] as? [String: Any],
              let command = toolInput["command"] as? String,
              PlaceholderParser.containsMarker(command)
        else { return nil }

        let requested = PlaceholderParser.names(in: command)
        guard !requested.isEmpty else { return nil }

        // Existence only — never the value. `try?` would be wrong here:
        // the store deliberately distinguishes a store-wide failure (this
        // throw) from a name simply being absent from a successful listing,
        // because a locked Keychain is a different problem from a typo and
        // the spec requires it be reported as one. Collapsing both into
        // "missing" would tell the user "secret introuvable, disponibles :
        // ..." while the truth is that the Keychain is locked and the list
        // is empty for the same reason.
        let available: [String]
        do {
            available = try store.names()
        } catch {
            return refusal(
                "Trousseau inaccessible (\(String(describing: error))). Aucune substitution effectuée. Déverrouiller le Trousseau puis réessayer."
            )
        }

        let known = Set(available)
        let missing = requested.filter { !known.contains($0) }
        guard missing.isEmpty else { return denial(missing: missing, available: available) }

        // Refuse the whole command rather than let a placeholder that
        // cannot safely expand where it sits travel to a provider as if it
        // were a credential (see CommandSubstitutionRewriter for why single
        // quotes are the case that cannot be made safe).
        let rewritten: String
        switch CommandSubstitutionRewriter.rewrite(command, binaryPath: binaryPath) {
        case .refusedInsideSingleQuotes(let name):
            return refusal(
                "Secret « \(name) » utilisé entre guillemets simples : le shell n'y développe pas $(...), donc la substitution y placerait le texte littéral au lieu de la valeur. Utiliser des guillemets doubles ou aucun guillemet autour de {{secret:\(name)}}."
            )
        case .rewritten(let rewrittenCommand):
            rewritten = rewrittenCommand
        }
        toolInput["command"] = rewritten

        let sessionID = root["session_id"] as? String ?? ""
        usage.record(names: requested, sessionID: sessionID)

        return encode([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "updatedInput": toolInput
            ]
        ])
    }

    private func denial(missing: [String], available: [String]) -> Data? {
        let known = available.isEmpty ? "aucun secret enregistré" : available.joined(separator: ", ")
        let subject = missing.count == 1
            ? "Secret « \(missing[0]) » introuvable."
            : "Secrets introuvables : \(missing.joined(separator: ", "))."
        return refusal("\(subject) Disponibles : \(known).")
    }

    /// A refusal never carries a secret VALUE, only names and error text.
    private func refusal(_ reason: String) -> Data? {
        encode([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason
            ]
        ])
    }

    // MARK: PostToolUse

    /// Fast path: no session file means this session has never had a
    /// secret substituted, so no output of any tool can contain one.
    /// That is a single stat() and an immediate exit, which is what makes
    /// a matcher of "*" affordable.
    public func runPost(input: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        let sessionID = root["session_id"] as? String ?? ""
        guard usage.hasAny(sessionID: sessionID) else { return nil }

        let used = usage.names(sessionID: sessionID)
        guard !used.isEmpty else { return nil }

        // Cheap check before the expensive one: no response, nothing to do.
        guard let response = root["tool_response"] else { return nil }

        // Read concurrently. Each read spawns /usr/bin/security, measured at
        // ~23 ms, and this runs on EVERY tool call for the rest of a session
        // that has used a secret. Sequentially, four used secrets would cost
        // ~91 ms per tool call, added even to tool calls unrelated to any
        // secret. Concurrently it is one read's latency regardless of count.
        var pairs: [(name: String, value: String)] = []
        var unreadable: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: used.count) { index in
            let name = used[index]
            if let value = try? store.value(for: name) {
                lock.lock(); pairs.append((name: name, value: value)); lock.unlock()
            } else {
                lock.lock(); unreadable.append(name); lock.unlock()
            }
        }

        // Never fail open in silence. runPost IS the safety net; a Keychain
        // that locked mid-session would otherwise disable it for the rest of
        // the session with no signal at all.
        if !unreadable.isEmpty {
            Self.warn("cannot read \(unreadable.count) secret(s) from the Keychain (\(unreadable.sorted().joined(separator: ", "))); the redaction net is incomplete for this tool call")
        }

        let redactor = SecretRedactor(secrets: pairs)
        guard !redactor.isEmpty else { return nil }

        var changed = false
        let redacted = SecretRedactor.redactStrings(in: response) { text in
            let out = redactor.redactKnownValues(text)
            if out != text { changed = true }
            return out
        }

        // Nothing leaked, so let the original output through untouched
        // rather than paying for a schema revalidation.
        guard changed else { return nil }

        return encode([
            "hookSpecificOutput": [
                "hookEventName": "PostToolUse",
                "updatedToolOutput": redacted
            ]
        ])
    }

    // MARK: SessionStart

    public func runSessionStart(input: Data) -> Data? {
        usage.prune(olderThan: 7 * 24 * 3600)

        let names = ((try? store.names()) ?? []).sorted()
        guard !names.isEmpty else { return nil }

        let context = """
        Secrets disponibles (valeurs inaccessibles, ne pas tenter de les lire) : \
        \(names.joined(separator: ", ")). \
        Pour en utiliser un, écrire {{secret:<nom>}} directement dans une commande Bash ; \
        la substitution a lieu à l'exécution et la valeur n'apparaît jamais ici.
        """

        return encode([
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": context
            ]
        ])
    }

    // suppressOutput is a TOP-LEVEL field on the hook output object (per
    // `claude --help`: "suppressOutput - Hide stdout from transcript
    // (default: false)"), sitting alongside stopReason/decision, not inside
    // hookSpecificOutput. Without it, Claude Code writes this hook's own
    // stdout verbatim into the session transcript as a `hook_success`
    // attachment. For hook-pre that stdout IS updatedInput, which for a
    // substituted secret contains the real value — so the mechanism that
    // exists to keep a secret out of the transcript would otherwise put it
    // there itself. Found by an end-to-end canary test (a disposable secret
    // turned up in the transcript file on disk); no unit test caught it
    // because unit tests only ever look at this function's return value,
    // never at what Claude Code does with it afterward. Applied here, in the
    // one shared encoder, so every hook response gets it and nothing added
    // later can forget it.
    fileprivate func encode(_ object: [String: Any]) -> Data? {
        var withSuppressedOutput = object
        withSuppressedOutput["suppressOutput"] = true
        return try? JSONSerialization.data(withJSONObject: withSuppressedOutput, options: [.withoutEscapingSlashes])
    }

    /// Diagnostics go to stderr, never stdout: stdout carries the hook's JSON
    /// protocol and anything written there would corrupt it.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("opus-secrets: \(message)\n".utf8))
    }
}
