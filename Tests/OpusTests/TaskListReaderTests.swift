import XCTest
@testable import Opus

final class TaskListReaderTests: XCTestCase {
    // MARK: parse

    func testParsesATask() {
        let raw = #"{"id":"1","subject":"Lot A: encodeur WebP","description":"…","activeForm":"Ajout","status":"completed","blocks":[],"blockedBy":[]}"#
        let t = TaskListReader.parse(fileContents: Data(raw.utf8))
        XCTAssertEqual(t?.id, "1")
        XCTAssertEqual(t?.subject, "Lot A: encodeur WebP")
        XCTAssertEqual(t?.status, .completed)
    }

    func testUnknownStatusFallsBackToPending() {
        let raw = #"{"id":"2","subject":"x","status":"weird"}"#
        XCTAssertEqual(TaskListReader.parse(fileContents: Data(raw.utf8))?.status, .pending)
    }

    func testMalformedIsNil() {
        XCTAssertNil(TaskListReader.parse(fileContents: Data("nope".utf8)))
    }

    // MARK: load

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opus-tasklistreader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadIgnoresLockAndHighwatermarkAndSortsNumerically() throws {
        // .lock / .highwatermark live in the same directory; only numeric
        // *.json count, and "10.json" must sort after "2.json".
        let sessionId = "11111111-1111-1111-1111-111111111111"
        let dir = root.appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("1.json", #"{"id":"1","subject":"first","status":"completed"}"#)
        try write("2.json", #"{"id":"2","subject":"second","status":"pending"}"#)
        try write("10.json", #"{"id":"10","subject":"tenth","status":"in_progress"}"#)
        // Not tasks — must be ignored outright, not handed to parse (which
        // would fail on their content anyway, but they must never even be
        // attempted: an empty .lock isn't valid JSON, and a plain digit
        // inside .highwatermark isn't a JSON object either).
        try write(".lock", "")
        try write(".highwatermark", "3")

        let tasks = TaskListReader.load(sessionId: sessionId, tasksDir: root)
        XCTAssertEqual(tasks.map(\.id), ["1", "2", "10"])
        XCTAssertEqual(tasks.map(\.subject), ["first", "second", "tenth"])
        XCTAssertEqual(tasks.map(\.status), [.completed, .pending, .inProgress])
    }
}
