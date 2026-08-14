import XCTest
@testable import OpusScriptsKit

/// The registry reads a directory of shell scripts and turns them into rows
/// for the panel. Everything here runs against a temp directory — no test
/// touches the real ~/.opus/scripts.
final class ScriptRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opus-scripts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, _ body: String, executable: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: Header parsing

    func testReadsTheDisplayNameAndDescriptionFromTheHeader() throws {
        try write("veille.sh", """
        #!/bin/zsh
        # opus: Garder l'écran allumé
        # opus-desc: Empêche la mise en veille tant que le script tourne.
        caffeinate -d
        """)
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0].displayName, "Garder l'écran allumé")
        XCTAssertEqual(scripts[0].summary, "Empêche la mise en veille tant que le script tourne.")
    }

    /// A script with no header is still perfectly runnable. Refusing to list
    /// it would mean a file dropped in the folder silently does not exist.
    func testAScriptWithNoHeaderFallsBackToItsFilename() throws {
        try write("backup-photos.sh", "#!/bin/zsh\necho hi\n")
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0].displayName, "backup-photos")
        XCTAssertEqual(scripts[0].summary, "")
    }

    func testHeaderKeysAreOnlyReadNearTheTopOfTheFile() throws {
        var body = "#!/bin/zsh\n"
        for index in 0..<40 { body += "echo line \(index)\n" }
        body += "# opus: Trop bas pour compter\n"
        try write("late.sh", body)
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts[0].displayName, "late",
                       "a header buried in the body is a coincidence, not a declaration")
    }

    func testAHeaderKeyWithNoValueIsIgnoredRatherThanSettingAnEmptyName() throws {
        try write("blank.sh", "#!/bin/zsh\n# opus:\n# opus-desc:   \n")
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts[0].displayName, "blank")
        XCTAssertEqual(scripts[0].summary, "")
    }

    // MARK: What counts as a script

    func testOnlyExecutableFilesAreListed() throws {
        try write("runnable.sh", "#!/bin/zsh\n", executable: true)
        try write("notes.sh", "#!/bin/zsh\n", executable: false)
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts.map(\.displayName), ["runnable"],
                       "a non-executable file cannot be launched, so listing it promises a lie")
    }

    func testHiddenFilesAndDirectoriesAreSkipped() throws {
        try write(".hidden.sh", "#!/bin/zsh\n")
        try write("real.sh", "#!/bin/zsh\n")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts.map(\.displayName), ["real"])
    }

    func testAMissingDirectoryIsAnEmptyListNotAnError() throws {
        let absent = root.appendingPathComponent("does-not-exist")
        XCTAssertEqual(try ScriptRegistry.scan(directory: absent).count, 0,
                       "the folder not existing yet is the normal first-run state")
    }

    // MARK: Ordering and identity

    func testScriptsAreSortedByDisplayNameCaseInsensitively() throws {
        try write("b.sh", "#!/bin/zsh\n# opus: zebra\n")
        try write("a.sh", "#!/bin/zsh\n# opus: Alpha\n")
        try write("c.sh", "#!/bin/zsh\n# opus: mango\n")
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts.map(\.displayName), ["Alpha", "mango", "zebra"])
    }

    /// Identity is the path, never the display name: two scripts may legally
    /// share a display name, and run state is tracked per file.
    func testIdentityIsThePathNotTheDisplayName() throws {
        try write("one.sh", "#!/bin/zsh\n# opus: Même nom\n")
        try write("two.sh", "#!/bin/zsh\n# opus: Même nom\n")
        let scripts = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(Set(scripts.map(\.id)).count, 2)
    }

    // MARK: Filtering

    func testFilterMatchesDisplayNameAndSummaryCaseInsensitively() throws {
        try write("a.sh", "#!/bin/zsh\n# opus: Sauvegarde photos\n# opus-desc: vers le NAS\n")
        try write("b.sh", "#!/bin/zsh\n# opus: Nettoyage caches\n")
        let all = try ScriptRegistry.scan(directory: root)
        XCTAssertEqual(ScriptRegistry.filter(all, query: "PHOTO").map(\.displayName),
                       ["Sauvegarde photos"])
        XCTAssertEqual(ScriptRegistry.filter(all, query: "nas").map(\.displayName),
                       ["Sauvegarde photos"], "the summary is searchable too")
        XCTAssertEqual(ScriptRegistry.filter(all, query: "   ").count, 2,
                       "a blank query is not a filter")
    }
}
