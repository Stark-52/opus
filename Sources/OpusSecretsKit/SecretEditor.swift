// SecretEditor — the "modify a secret already in the store" composition:
// rename it, replace its value, or both, decided in one place.
//
// Kept out of SecretsPanel for the same reason SecretRenamer is: the panel
// can only ever be tried by hand, and the interesting cases here are the
// partial failures — a rename that lands while the value write behind it
// does not — which are exactly the ones nobody reproduces by clicking.
//
// Renaming delegates to SecretRenamer rather than reimplementing the
// move: a second copy of "write the new name, then remove the old" would
// be a second place for the partial-failure reporting to drift. The cost
// is one extra write when the name AND the value both change (the rename
// carries the old value across, then the new value overwrites it), which
// is two `security` calls on a value already capped at 8 KB.
//
// Values pass through Swift memory only, never argv, never printed.

import Foundation

public enum SecretEditOutcome: Equatable {
    /// Same name, empty value field: the user committed a no-op.
    case unchanged
    case renamed(newName: String)
    case valueReplaced(name: String)
    case renamedAndValueReplaced(newName: String)
    /// `slug(rawNewName)` came back empty or unusable.
    case invalidNewName(raw: String)
    case notFound(available: [String])
    case newNameAlreadyExists(newName: String)
    /// The rename landed but the value write behind it did not: the secret
    /// now lives under `newName` carrying its OLD value. Reported as its
    /// own case rather than folded into storeError, because the name the
    /// caller must now show the user is the NEW one.
    case renamedButValueFailed(newName: String, error: String)
    case newWrittenOldRemains(newName: String, oldName: String, removeError: String)
    case storeError(String)
}

public enum SecretEditor {
    /// - Parameters:
    ///   - original: the name the secret is stored under right now.
    ///   - rawNewName: what the user left in the name field, hand-typed, so
    ///     it goes through `SecretName.slug` exactly like a fresh deposit.
    ///     Equal to `original` means "not renaming".
    ///   - newValue: empty means "leave the value alone". A value that is
    ///     only whitespace is NOT treated as empty: the store's own
    ///     validator owns what a legal value is, and second-guessing it
    ///     here would let the two disagree.
    public static func edit(_ store: SecretStore,
                            original: String,
                            rawNewName: String,
                            newValue: String) -> SecretEditOutcome {
        let newName = SecretName.slug(rawNewName)
        guard SecretName.isValid(newName) else { return .invalidNewName(raw: rawNewName) }

        let renaming = newName != original
        let replacingValue = !newValue.isEmpty

        if renaming {
            switch SecretRenamer.rename(store, from: original, toRaw: rawNewName) {
            case .renamed(let landed):
                guard replacingValue else { return .renamed(newName: landed) }
                do {
                    try store.put(name: landed, value: newValue)
                } catch {
                    return .renamedButValueFailed(newName: landed, error: "\(error)")
                }
                return .renamedAndValueReplaced(newName: landed)
            case .invalidNewName(let raw):
                return .invalidNewName(raw: raw)
            case .oldNameNotFound(let available):
                return .notFound(available: available)
            case .newNameAlreadyExists(let name):
                return .newNameAlreadyExists(newName: name)
            case .newWrittenOldRemains(let newName, let oldName, let removeError):
                // The value is deliberately NOT written on top of a
                // half-finished move: the secret exists under both names
                // and writing again would make one of them newer than the
                // other while the caller is still being told to go clean up.
                return .newWrittenOldRemains(newName: newName, oldName: oldName, removeError: removeError)
            case .storeError(let message):
                return .storeError(message)
            }
        }

        guard replacingValue else { return .unchanged }

        // Value-only path. Fail CLOSED on an unreadable name list, the same
        // way a fresh deposit does: `put` replaces in place with no warning,
        // so without the list there is no way to tell "replacing the value
        // of a secret that exists" from "silently creating a new one".
        let available: [String]
        do {
            available = try store.names()
        } catch {
            return .storeError("\(error)")
        }
        guard available.contains(original) else { return .notFound(available: available) }
        do {
            try store.put(name: original, value: newValue)
        } catch {
            return .storeError("\(error)")
        }
        return .valueReplaced(name: original)
    }
}
