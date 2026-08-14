// SecretRenamer — the `rename` composition, kept apart from opus-secrets'
// main.swift so it can be exercised against InMemorySecretStore instead of
// only ever tried by hand against the real Keychain.
//
// Composed from the three primitives already on SecretStore (value/put/
// remove) rather than added as a fourth store primitive: KeychainSecretStore
// only ever talks to `security` through those three shapes, and a rename
// that needed a new subprocess shape just for itself would be one more way
// for the Keychain-backed store to diverge from `get`/`put`/`rm`.
//
// The value passes through Swift memory only — read here, handed straight
// to `put` — never argv, never a shell variable, never printed.

import Foundation

public enum SecretRenameOutcome: Equatable {
    case renamed(newName: String)
    /// `slug(rawNewName)` came back empty: nothing usable survived.
    case invalidNewName(raw: String)
    case oldNameNotFound(available: [String])
    case newNameAlreadyExists(newName: String)
    /// `put` under the new name succeeded but `remove` of the old one then
    /// failed: the value now lives under BOTH names and the caller must say
    /// so explicitly rather than report a clean rename.
    case newWrittenOldRemains(newName: String, oldName: String, removeError: String)
    /// A real store failure (locked Keychain, etc.) surfaced by `names()`,
    /// `value(for:)` or `put`. Never flattened into `oldNameNotFound`.
    case storeError(String)
}

public enum SecretRenamer {
    /// - Parameters:
    ///   - oldName: taken as-is; only ever matched against what `names()`
    ///     actually returns, so a name outside the grammar simply cannot
    ///     match and falls out as `oldNameNotFound` like any other typo.
    ///   - rawNewName: run through `SecretName.slug` here, the same
    ///     normalization `put` expects a caller to have already applied to
    ///     a hand-typed name, so `rename stripe-key "stripe live"` lands on
    ///     `stripe-live`.
    public static func rename(_ store: SecretStore, from oldName: String, toRaw rawNewName: String) -> SecretRenameOutcome {
        let newName = SecretName.slug(rawNewName)
        guard SecretName.isValid(newName) else {
            return .invalidNewName(raw: rawNewName)
        }

        let available: [String]
        do {
            available = try store.names()
        } catch {
            return .storeError("\(error)")
        }
        guard available.contains(oldName) else {
            return .oldNameNotFound(available: available)
        }
        guard !available.contains(newName) else {
            return .newNameAlreadyExists(newName: newName)
        }

        let value: String
        do {
            value = try store.value(for: oldName)
        } catch {
            return .storeError("\(error)")
        }
        do {
            try store.put(name: newName, value: value)
        } catch {
            return .storeError("\(error)")
        }
        do {
            try store.remove(name: oldName)
        } catch {
            return .newWrittenOldRemains(newName: newName, oldName: oldName, removeError: "\(error)")
        }
        return .renamed(newName: newName)
    }
}
