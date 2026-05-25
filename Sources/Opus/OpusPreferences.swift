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

/// Which surfaces Opus exposes the shared Claude session through. All
/// combinations keep tab 0 of every surface subscribed to the same
/// ClaudeBackend broadcast, so what you type in one shows everywhere.
enum OpusDisplayMode: String, CaseIterable {
    /// Native Terminal.app window via opus-attach + slide-down panel.
    case nativeAndPanel = "nativeAndPanel"
    /// Slide-down panel + Main window (NSWindow). No Terminal.app.
    case panelAndMain   = "panelAndMain"
    /// Slide-down panel only.
    case panelOnly      = "panelOnly"
    /// Main window only.
    case mainOnly       = "mainOnly"

    var displayName: String {
        switch self {
        case .nativeAndPanel: return "Terminal.app + Quick Terminal"
        case .panelAndMain:   return "Quick Terminal + Main Window"
        case .panelOnly:      return "Quick Terminal only"
        case .mainOnly:       return "Main Window only"
        }
    }

    var includesNativeTerminal: Bool { self == .nativeAndPanel }
    var includesPanel: Bool { self != .mainOnly }
    var includesMain:  Bool { self == .panelAndMain || self == .mainOnly }
}

final class OpusPreferences {
    static let shared = OpusPreferences()
    private let defaults = UserDefaults.standard

    // MARK: Keys (kept private to force access through the typed properties below)

    private enum K {
        static let initialCommandPreset = "opus.initialCommandPreset"
        static let customCommand        = "opus.customCommand"
        static let workingDirectory     = "opus.workingDirectory"
        static let displayMode          = "opus.displayMode"
        static let onboardingShown      = "opus.onboardingShown"
        // Appearance (used in Phase 4)
        static let appearanceMode       = "opus.appearanceMode"
        static let appearanceTintRGBA   = "opus.appearanceTintRGBA"
        static let appearanceImagePath  = "opus.appearanceImagePath"
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

    var displayMode: OpusDisplayMode {
        get {
            let raw = defaults.string(forKey: K.displayMode) ?? OpusDisplayMode.nativeAndPanel.rawValue
            return OpusDisplayMode(rawValue: raw) ?? .nativeAndPanel
        }
        set { write(K.displayMode, newValue.rawValue) }
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
