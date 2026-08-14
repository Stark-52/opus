import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Finds the scripts on disk and turns them into rows.
///
/// The folder IS the database. There is no index file to keep in sync, no
/// registration step: drop an executable file in, it appears; delete it, it
/// is gone. That is the whole point of the design — Claude writes a file with
/// an ordinary editor and the panel picks it up.
public enum ScriptRegistry {
    /// Where scripts live. Not under ~/.claude: these belong to Opus, and
    /// mixing them into Claude Code's own configuration directory would make
    /// them look like something Claude Code reads.
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".opus")
            .appendingPathComponent("scripts")
    }

    /// Lists the runnable scripts in `directory`, sorted for display.
    ///
    /// A directory that does not exist yet returns an empty list rather than
    /// throwing: that is the normal state before the first script is written,
    /// not a failure the user should see reported as one.
    public static func scan(directory: URL) throws -> [ScriptDefinition] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        let entries = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        let scripts: [ScriptDefinition] = entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            // Both conditions matter. A directory is not a script, and a file
            // without the executable bit cannot be launched — listing it would
            // offer the user a button that can only ever fail.
            guard values?.isRegularFile == true, values?.isExecutable == true else { return nil }

            let header = readHeader(of: url)
            let parsed = ScriptHeader.parse(header)
            return ScriptDefinition(
                url: url,
                displayName: parsed.name.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.name,
                summary: parsed.summary,
                // Validated here, not at draw time: a typo'd symbol name
                // yields a nil NSImage, and a row with a hole where its glyph
                // should be looks broken rather than plain.
                iconName: resolvedIcon(parsed.icon)
            )
        }

        return scripts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Narrows the list by a free-text query over name AND summary. A blank
    /// query is not a filter — it returns everything rather than nothing,
    /// which is what an empty search field should mean.
    public static func filter(_ scripts: [ScriptDefinition], query: String) -> [ScriptDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return scripts }
        return scripts.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.summary.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Falls back to the default glyph when a script declares nothing, or
    /// declares a name that is not a real SF Symbol on this system.
    static func resolvedIcon(_ declared: String) -> String {
        guard !declared.isEmpty, isKnownSymbol(declared) else { return ScriptHeader.defaultIcon }
        return declared
    }

    /// Overridden in tests, which run without AppKit's symbol catalogue.
    static var isKnownSymbol: (String) -> Bool = { name in
        #if canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return true
        #endif
    }

    /// Reads only enough of the file to cover the header window. Scripts can
    /// be large; the scan runs on every panel open and must not depend on
    /// their size.
    private static func readHeader(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        // 8 KB comfortably covers 20 lines of comment. A binary executable
        // read this way yields bytes that are not valid UTF-8, which decodes
        // to nil and falls through to the filename — the right answer for a
        // compiled helper someone dropped in the folder.
        let data = (try? handle.read(upToCount: 8 * 1024)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
