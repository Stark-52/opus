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

/// How a spawned claude reattaches to past conversations.
enum OpusResumeMode: Equatable {
    case none
    case continueMostRecent            // claude --continue
    case resume(sessionId: String)     // claude --resume <id>
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
        static let initialCommandPreset   = "opus.initialCommandPreset"
        static let customCommand          = "opus.customCommand"
        static let workingDirectory       = "opus.workingDirectory"
        static let displayMode            = "opus.displayMode"
        static let onboardingShown        = "opus.onboardingShown"
        static let skipPermissions        = "opus.skipPermissions"
        static let resumeLastConversation = "opus.resumeLastConversation"
        // Appearance (used in Phase 4)
        static let appearanceMode         = "opus.appearanceMode"
        static let appearanceTintRGBA     = "opus.appearanceTintRGBA"
        static let appearanceImagePath    = "opus.appearanceImagePath"
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

    /// Default for new Opus launches — ClaudeBackend seeds its runtime
    /// `skipPermissionsActive` from this. The shield button flips the runtime
    /// state without touching this default.
    var skipPermissions: Bool {
        get { defaults.bool(forKey: K.skipPermissions) }
        set { write(K.skipPermissions, newValue) }
    }

    /// Launch claude with --continue so the most recent conversation in the
    /// working directory reopens on Opus start.
    var resumeLastConversation: Bool {
        get { defaults.bool(forKey: K.resumeLastConversation) }
        set { write(K.resumeLastConversation, newValue) }
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

    /// Pure command builder — static so tests exercise it without UserDefaults.
    /// Launch flags (skip-permissions, resume) only apply to the .claude
    /// preset: .shell doesn't run claude and .custom runs the user's verbatim
    /// command (including its empty-string claude fallback).
    static func composeSpawnCommand(
        preset: OpusInitialCommandPreset,
        customCommand: String,
        workingDirectory: String,
        skipPermissions: Bool,
        resumeMode: OpusResumeMode
    ) -> String {
        let cwd = workingDirectory.replacingOccurrences(of: "\"", with: "\\\"")
        let cdPrefix = "cd \"\(cwd)\" && "
        switch preset {
        case .claude:
            var cmd = "command claude"
            if skipPermissions { cmd += " --dangerously-skip-permissions" }
            switch resumeMode {
            case .none: break
            case .continueMostRecent: cmd += " --continue"
            case .resume(let id): cmd += " --resume \(id)"  // IDs are UUID filenames from ClaudeSessionLocator — no shell metachars
            }
            return cdPrefix + cmd
        case .shell:
            return cdPrefix + "exec /bin/zsh -i"
        case .custom:
            let cmd = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? cdPrefix + "command claude" : cdPrefix + cmd
        }
    }

    /// The actual shell command to run inside the spawned zsh. Default args
    /// keep existing call sites (private tabs) compiling with no flags.
    func resolvedSpawnCommand(
        skipPermissions: Bool = false,
        resumeMode: OpusResumeMode = .none
    ) -> String {
        Self.composeSpawnCommand(
            preset: initialCommandPreset,
            customCommand: customCommand,
            workingDirectory: workingDirectory,
            skipPermissions: skipPermissions,
            resumeMode: resumeMode
        )
    }

    // MARK: Internal

    private func write(_ key: String, _ value: Any?) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .opusPreferencesDidChange, object: nil)
    }

    private init() {}
}
