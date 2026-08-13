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

import Foundation

public struct HookRunner {
    private let store: SecretStore
    private let usage: SessionUsage

    public init(store: SecretStore, usage: SessionUsage) {
        self.store = store
        self.usage = usage
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

        // `try?` would be wrong here. The store deliberately distinguishes
        // `.notFound` from `.commandFailed`, because a locked Keychain is a
        // different problem from a typo and the spec requires it be reported
        // as one. Collapsing both into "missing" would tell the user
        // "secret introuvable, disponibles : ..." while the truth is that
        // the Keychain is locked and the list is empty for the same reason.
        var values: [String: String] = [:]
        var missing: [String] = []
        var storeFailure: String?
        for name in requested {
            do {
                values[name] = try store.value(for: name)
            } catch SecretStoreError.notFound {
                missing.append(name)
            } catch {
                storeFailure = String(describing: error)
                break
            }
        }

        // Refuse the whole command rather than let an unresolved
        // placeholder travel to a provider as if it were a credential.
        if let storeFailure {
            return refusal(
                "Trousseau inaccessible (\(storeFailure)). Aucune substitution effectuée. Déverrouiller le Trousseau puis réessayer."
            )
        }
        guard missing.isEmpty else { return denial(missing: missing) }

        toolInput["command"] = PlaceholderParser.substitute(command, values: values)

        let sessionID = root["session_id"] as? String ?? ""
        usage.record(names: requested, sessionID: sessionID)

        return encode([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "updatedInput": toolInput
            ]
        ])
    }

    private func denial(missing: [String]) -> Data? {
        let available = (try? store.names()) ?? []
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

        let pairs: [(name: String, value: String)] = used.compactMap { name in
            guard let value = try? store.value(for: name) else { return nil }
            return (name: name, value: value)
        }
        let redactor = SecretRedactor(secrets: pairs)
        guard !redactor.isEmpty else { return nil }

        guard let response = root["tool_response"] else { return nil }

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

    fileprivate func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
