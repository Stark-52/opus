import XCTest
@testable import Opus

/// PathDetector.extract is pure — no FileManager, no AppKit. These tests
/// exercise the token-scan/parse logic directly by constructing lines and
/// click columns the way TerminalContainerView's hit-test would.
final class PathDetectorTests: XCTestCase {
    private let cwd = "/Users/dev/project"

    func testMidClickOnFilePathWithLineNumber() {
        // "src/Foo.swift:42" — column 5 lands on the 'o' in "Foo", mid-token.
        let result = PathDetector.extract(line: "src/Foo.swift:42", clickColumn: 5, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/src/Foo.swift")
        XCTAssertEqual(result?.line, 42)
    }

    func testAbsolutePathUnchanged() {
        let result = PathDetector.extract(line: "/usr/local/bin/foo.sh", clickColumn: 6, cwd: cwd)
        XCTAssertEqual(result?.path, "/usr/local/bin/foo.sh")
        XCTAssertNil(result?.line)
    }

    func testTildeExpansion() {
        let result = PathDetector.extract(line: "~/x", clickColumn: 2, cwd: cwd)
        XCTAssertEqual(result?.path, NSHomeDirectory() + "/x")
        XCTAssertNil(result?.line)
    }

    func testBareWordWithoutSlashOrDotReturnsNil() {
        let result = PathDetector.extract(line: "hello world", clickColumn: 2, cwd: cwd)
        XCTAssertNil(result)
    }

    func testClickOnSpaceReturnsNil() {
        // "cd src/a.swift" — column 2 is the space between "cd" and the path.
        let result = PathDetector.extract(line: "cd src/a.swift", clickColumn: 2, cwd: cwd)
        XCTAssertNil(result)
    }

    func testWrappersStripped() {
        // "(src/a.swift:3)," — click on the 'a' inside "a.swift".
        let result = PathDetector.extract(line: "(src/a.swift:3),", clickColumn: 5, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/src/a.swift")
        XCTAssertEqual(result?.line, 3)
    }

    func testTrailingLineAndColSuffixDiscardsCol() {
        let result = PathDetector.extract(line: "src/Foo.swift:12:5", clickColumn: 5, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/src/Foo.swift")
        XCTAssertEqual(result?.line, 12)
    }

    func testRelativeResolutionAgainstCwd() {
        let result = PathDetector.extract(line: "lib/util.py", clickColumn: 0, cwd: "/Users/dev/app")
        XCTAssertEqual(result?.path, "/Users/dev/app/lib/util.py")
    }

    func testClampOutOfRangeColumnHigh() {
        // clickColumn far past the line's length clamps to the last char
        // (still inside the token) rather than crashing or returning nil.
        let result = PathDetector.extract(line: "src/Foo.swift", clickColumn: 9999, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/src/Foo.swift")
    }

    func testClampOutOfRangeColumnNegative() {
        let result = PathDetector.extract(line: "src/Foo.swift", clickColumn: -10, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/src/Foo.swift")
    }

    func testEmptyLineReturnsNil() {
        XCTAssertNil(PathDetector.extract(line: "", clickColumn: 0, cwd: cwd))
    }

    func testClickOnWrapperCharItselfReturnsNil() {
        // Column 0 is '(' — not a token char, even though a valid path
        // immediately follows it.
        let result = PathDetector.extract(line: "(src/a.swift)", clickColumn: 0, cwd: cwd)
        XCTAssertNil(result)
    }
}
