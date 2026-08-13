import XCTest
@testable import OpusSecretsKit

final class SessionUsageTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-secrets-usage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testHasAnyIsFalseBeforeAnythingIsRecorded() {
        let usage = SessionUsage(directory: dir)
        XCTAssertFalse(usage.hasAny(sessionID: "s1"))
        XCTAssertEqual(usage.names(sessionID: "s1"), [])
    }

    func testRecordThenRead() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["resend", "asc"], sessionID: "s1")
        XCTAssertTrue(usage.hasAny(sessionID: "s1"))
        XCTAssertEqual(usage.names(sessionID: "s1").sorted(), ["asc", "resend"])
    }

    func testRecordAccumulatesAcrossCallsAndDeduplicates() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["a"], sessionID: "s1")
        usage.record(names: ["a", "b"], sessionID: "s1")
        XCTAssertEqual(usage.names(sessionID: "s1").sorted(), ["a", "b"])
    }

    func testSessionsAreIsolated() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["a"], sessionID: "s1")
        XCTAssertFalse(usage.hasAny(sessionID: "s2"))
    }

    func testInvalidNamesAreNeverRecorded() {
        // The file is read back and its contents used as store lookups, so
        // it must not become an injection surface.
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["ok", "../escape", "UPPER"], sessionID: "s1")
        XCTAssertEqual(usage.names(sessionID: "s1"), ["ok"])
    }

    func testSessionIDWithPathSeparatorsCannotEscapeTheDirectory() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["a"], sessionID: "../../etc/passwd")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(contents, ["etcpasswd.names"])
    }

    func testFileIsOwnerReadableOnly() throws {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["a"], sessionID: "s1")
        let file = dir.appendingPathComponent("s1.names")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testPruneRemovesOldFilesAndKeepsRecentOnes() throws {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["a"], sessionID: "old")
        usage.record(names: ["b"], sessionID: "new")

        let old = dir.appendingPathComponent("old.names")
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

        usage.prune(olderThan: 7 * 24 * 3600, now: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(usage.hasAny(sessionID: "new"))
    }

    func testConcurrentRecordsDoNotLoseNames() {
        // The read-merge-overwrite this replaced lost names here: two writers
        // both read the old set, then the second overwrote the first. Claude
        // Code's parallel tool calls make that the normal case, not a corner.
        let usage = SessionUsage(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            usage.record(names: ["name-\(i)"], sessionID: "s1")
        }
        XCTAssertEqual(usage.names(sessionID: "s1").count, 50)
    }

    func testNamesDeduplicatesRepeatedRecords() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["a"], sessionID: "s1")
        usage.record(names: ["a", "b"], sessionID: "s1")
        usage.record(names: ["a"], sessionID: "s1")
        XCTAssertEqual(usage.names(sessionID: "s1").sorted(), ["a", "b"])
    }

    func testDirectoryModeIsEnforcedEvenWhenItAlreadyExists() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        SessionUsage(directory: dir).record(names: ["a"], sessionID: "s1")
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(attrs?[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testPruneOnAMissingDirectoryDoesNotCrash() {
        let absent = dir.appendingPathComponent("never-created")
        SessionUsage(directory: absent).prune(olderThan: 1, now: Date())
    }
}
