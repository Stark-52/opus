// OpusPreferences — UserDefaults-backed settings singleton. Every
// configurable surface in Opus reads through this. Values are reactive via
// the `didChange` notification so multiple views can refresh in sync.

import Foundation
import AppKit

/// Posted whenever any preference is written. Observers (e.g. the panel's
/// appearance applier, ClaudeBackend's next spawn) read the current value.
extension Notification.Name {
    static let opusPreferencesDidChange = Notification.Name("com.andygarcia.opus.preferencesDidChange")
}

/// Initial-command presets the user picks from in Settings → General.
enum OpusInitialCommandPreset: String, CaseIterable {
    case claude = "claude"        // /bin/zsh -i -c "cd <cwd> && command claude"
    case shell  = "shell"         // /bin/zsh -i (interactive shell, no command)
    case custom = "custom"        // run the user-supplied custom command verbatim

    var displayName: String {
        switch self {
        case .claude: return "Claude (default)"
        case .shell:  return "Interactive shell"
        case .custom: return "Custom command…"
        }
    }
}

/// Pairing mode for Terminal.app integration. Mirror = launch Terminal.app +
/// opus-attach on startup so the panel and Terminal share one session.
/// Standalone = panel runs solo, no Terminal.app, no socket server.
enum OpusPairingMode: String, CaseIterable {
    case mirror     = "mirror"
    case standalone = "standalone"

    var displayName: String {
        switch self {
        case .mirror:     return "Mirror with Terminal.app"
        case .standalone: return "Standalone (panel only)"
        }
    }
}

final class OpusPreferences {
    static let shared = OpusPreferences()
    private let defaults = UserDefaults.standard

    // MARK: Keys (kept private to force access through the typed properties below)

    private enum K {
        static let initialCommandPreset = "opus.initialCommandPreset"
        static let customCommand        = "opus.customCommand"
        static let workingDirectory     = "opus.workingDirectory"
        static let pairingMode          = "opus.pairingMode"
        static let onboardingShown      = "opus.onboardingShown"
        // Appearance (used in Phase 4)
        static let appearanceMode       = "opus.appearanceMode"
        static let appearanceTintRGBA   = "opus.appearanceTintRGBA"
        static let appearanceImagePath  = "opus.appearanceImagePath"
        // Window mode (used in Phase 5)
        static let windowMode           = "opus.windowMode"
    }

    // MARK: Typed accessors

    var initialCommandPreset: OpusInitialCommandPreset {
        get {
            let raw = defaults.string(forKey: K.initialCommandPreset) ?? OpusInitialCommandPreset.claude.rawValue
            return OpusInitialCommandPreset(rawValue: raw) ?? .claude
        }
        set { write(K.initialCommandPreset, newValue.rawValue) }
    }

    var customCommand: String {
        get { defaults.string(forKey: K.customCommand) ?? "" }
        set { write(K.customCommand, newValue) }
    }

    var workingDirectory: String {
        get {
            defaults.string(forKey: K.workingDirectory)
                ?? (NSHomeDirectory() + "/Documents/GitHub/ClaudeUltra")
        }
        set { write(K.workingDirectory, newValue) }
    }

    var pairingMode: OpusPairingMode {
        get {
            let raw = defaults.string(forKey: K.pairingMode) ?? OpusPairingMode.mirror.rawValue
            return OpusPairingMode(rawValue: raw) ?? .mirror
        }
        set { write(K.pairingMode, newValue.rawValue) }
    }

    var onboardingShown: Bool {
        get { defaults.bool(forKey: K.onboardingShown) }
        set { write(K.onboardingShown, newValue) }
    }

    // Appearance — see Phase 4 for the consumers.
    var appearanceMode: String {
        get { defaults.string(forKey: K.appearanceMode) ?? "default" }
        set { write(K.appearanceMode, newValue) }
    }
    var appearanceTintRGBA: [Double] {
        get { (defaults.array(forKey: K.appearanceTintRGBA) as? [Double]) ?? [0.04, 0.05, 0.07, 0.55] }
        set { write(K.appearanceTintRGBA, newValue) }
    }
    var appearanceImagePath: String? {
        get { defaults.string(forKey: K.appearanceImagePath) }
        set { write(K.appearanceImagePath, newValue) }
    }

    // Window mode — see Phase 5.
    var windowMode: String {
        get { defaults.string(forKey: K.windowMode) ?? "panel" }
        set { write(K.windowMode, newValue) }
    }

    // MARK: Computed

    /// The actual shell command to run inside the spawned zsh, based on
    /// preset + custom + working directory.
    func resolvedSpawnCommand() -> String {
        let cwd = workingDirectory.replacingOccurrences(of: "\"", with: "\\\"")
        let cdPrefix = "cd \"\(cwd)\" && "
        switch initialCommandPreset {
        case .claude:
            return cdPrefix + "command claude"
        case .shell:
            return cdPrefix + "exec /bin/zsh -i"
        case .custom:
            let cmd = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? cdPrefix + "command claude" : cdPrefix + cmd
        }
    }

    // MARK: Internal

    private func write(_ key: String, _ value: Any?) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .opusPreferencesDidChange, object: nil)
    }

    private init() {}
}
