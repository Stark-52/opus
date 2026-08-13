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
            try? fm.createDirectory(
                atPath: (destination as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            let sourceData = try? Data(contentsOf: URL(fileURLWithPath: source))
            let destinationData = try? Data(contentsOf: URL(fileURLWithPath: destination))
            if sourceData != destinationData, let sourceData {
                try? fm.removeItem(atPath: destination)
                fm.createFile(atPath: destination, contents: sourceData,
                              attributes: [.posixPermissions: 0o755])
            }
        }

        var problems: [String] = []
        if let shimProblem = installShim() {
            problems.append(shimProblem)
        }

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
            problems.append("~/.claude/settings.json n'est pas du JSON valide. Les hooks de secrets ne sont pas installés et le fichier n'a pas été touché.")
        } catch ClaudeSettingsMergeError.backupFailed(let reason) {
            // A failed backup is a hard precondition failure, not malformed
            // JSON: apply() throws this BEFORE writing anything, specifically
            // because it refuses to touch the file without a safety copy.
            problems.append("Impossible de sauvegarder ~/.claude/settings.json avant modification (\(reason)). Les hooks de secrets ne sont pas installés et le fichier n'a pas été touché.")
        } catch {
            problems.append("Échec inattendu lors de l'installation des hooks de secrets (\(error)). Le fichier n'a pas été touché.")
        }

        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    /// Returns nil once ~/bin/secret is in place (written now, or already
    /// ours from a previous run), or a message when an unrecognised file
    /// there was left untouched. Never overwrites anything it did not write.
    private static func installShim() -> String? {
        let fm = FileManager.default
        let path = NSHomeDirectory() + "/bin/secret"

        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            // Only ever replace a shim we recognise as ours.
            guard existing.contains("opus-secrets") else {
                return "~/bin/secret existe déjà et ne vient pas d'Opus : laissé inchangé. La commande `secret` n'utilisera pas opus-secrets tant que ce fichier occupe le chemin."
            }
            guard existing != shimBody else { return nil }
        }

        try? fm.createDirectory(atPath: NSHomeDirectory() + "/bin", withIntermediateDirectories: true)
        try? fm.removeItem(atPath: path)
        fm.createFile(atPath: path, contents: Data(shimBody.utf8),
                      attributes: [.posixPermissions: 0o755])
        return nil
    }
}
