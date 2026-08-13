// SecretsInstaller — puts opus-secrets where the hooks can find it, then
// registers those hooks in the user's own settings.
//
// ~/.local/bin is Opus's existing convention for its companion binaries:
// it is HookSettingsWriter.bundledBinaryPath's fallback for opus-attach and
// SpawnEnvironment already adds it to PATH. The hooks reference the
// absolute path regardless, so PATH membership is a convenience, not a
// requirement.
//
// The `secret` shim goes to ~/bin instead, because that is where the owner's
// hand already goes. It is only written when the path is free or already
// holds a shim we wrote: an unrecognised file there is left alone and
// reported.

import Foundation
import OpusSecretsKit

enum SecretsInstaller {
    private static let shimBody = """
    #!/bin/sh
    # Généré par Opus. Passe-plat vers opus-secrets.
    exec "$HOME/.local/bin/opus-secrets" "$@"
    """

    static var installedBinaryPath: String {
        NSHomeDirectory() + "/.local/bin/opus-secrets"
    }

    private static var bundledBinaryPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/MacOS/opus-secrets"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    private static var backupURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json.opus-bak")
    }

    /// Returns nil on success, or a message describing what could not be done.
    @discardableResult
    static func install() -> String? {
        let fm = FileManager.default

        if let source = bundledBinaryPath {
            let destination = installedBinaryPath
            try? fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            let sourceData = try? Data(contentsOf: URL(fileURLWithPath: source))
            let destinationData = try? Data(contentsOf: URL(fileURLWithPath: destination))
            if let sourceData, sourceData != destinationData {
                do {
                    try sourceData.write(to: URL(fileURLWithPath: destination), options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
                    NSLog("Opus: installed opus-secrets to \(destination)")
                } catch {
                    // Do not register hooks pointing at a binary that is not
                    // there. Returning here leaves whatever was already
                    // installed, and the settings untouched.
                    return "impossible d'installer opus-secrets : \(error.localizedDescription). Les hooks ne sont pas enregistrés."
                }
            }
        }

        // A conflicting ~/bin/secret is a note for the user, not a reason to
        // skip installing the hooks: it only affects the interactive shim,
        // not hook substitution/redaction, which use the binary directly.
        let shimProblem = installShim()

        do {
            let changed = try ClaudeSettingsMerger.apply(
                settingsURL: settingsURL,
                backupURL: backupURL,
                binaryPath: installedBinaryPath,
                timeoutSeconds: HookSettingsWriter.timeoutSeconds
            )
            if changed {
                NSLog("Opus: secrets hooks registered in ~/.claude/settings.json")
            }
        } catch ClaudeSettingsMergeError.malformedExistingFile {
            return "~/.claude/settings.json n'est pas du JSON valide. Les hooks de secrets ne sont pas installés et le fichier n'a pas été touché."
        } catch ClaudeSettingsMergeError.unreadableExistingFile(let reason) {
            return "~/.claude/settings.json existe mais n'est pas lisible (\(reason)). Les hooks de secrets ne sont pas installés et le fichier n'a pas été touché."
        } catch ClaudeSettingsMergeError.backupFailed(let reason) {
            // A failed backup is a hard precondition failure, not malformed
            // JSON: apply() throws this BEFORE writing anything, specifically
            // because it refuses to touch the file without a safety copy.
            return "Impossible de sauvegarder ~/.claude/settings.json avant modification (\(reason)). Les hooks de secrets ne sont pas installés et le fichier n'a pas été touché."
        } catch {
            return "Échec inattendu lors de l'installation des hooks de secrets (\(error)). Le fichier n'a pas été touché."
        }

        // The merge succeeded (or was already a no-op): a shim conflict, if
        // any, is the only thing left to tell the user about.
        return shimProblem
    }

    /// Returns nil once ~/bin/secret is in place (written now, or already
    /// ours from a previous run), or a message when an unrecognised or
    /// unreadable file there was left untouched. Never overwrites anything
    /// it did not write.
    private static func installShim() -> String? {
        let fm = FileManager.default
        let path = NSHomeDirectory() + "/bin/secret"

        if fm.fileExists(atPath: path) {
            // Existence and readability are different questions. `try?` alone
            // collapses them, and falling through on an unreadable file would
            // overwrite something Opus did not write, which is the one thing
            // this function promises never to do.
            guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else {
                return "~/bin/secret existe mais n'est pas lisible en UTF-8. Laissé intact, le shim n'est pas installé."
            }
            guard existing.contains("opus-secrets") else {
                return "~/bin/secret existe et n'a pas été écrit par Opus. Laissé intact, utiliser opus-secrets directement."
            }
            guard existing != shimBody else { return nil }
        }

        try? fm.createDirectory(atPath: NSHomeDirectory() + "/bin", withIntermediateDirectories: true)
        do {
            // Atomic write, never removeItem-then-create: a failed write must
            // not leave nothing where a working shim used to be.
            try Data(shimBody.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        } catch {
            return "impossible d'écrire ~/bin/secret : \(error.localizedDescription)"
        }
        return nil
    }
}
