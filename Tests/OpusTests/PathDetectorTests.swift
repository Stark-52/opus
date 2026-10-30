import XCTest
@testable import OpusArtifactsKit

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

    // MARK: Fix round 1 — sentence-ending dot glued to a bare file mention

    func testSentenceEndingDotIsSwallowedIntoTheRawToken() {
        // Documents the raw (pre-fix) behavior at the PathDetector layer:
        // '.' is a token char, so the scan can't distinguish a file
        // extension's dot from a sentence-ending period immediately after
        // it. TerminalContainerView is the one that retries with
        // trailingDotStripped when this doesn't exist on disk.
        let line = "The fix is in src/Foo.swift. Please check."
        let result = PathDetector.extract(line: line, clickColumn: 18, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/src/Foo.swift.")
    }

    func testTrailingDotStrippedRecoversTheRealPath() {
        XCTAssertEqual(PathDetector.trailingDotStripped("/Users/dev/project/src/Foo.swift."),
                        "/Users/dev/project/src/Foo.swift")
    }

    func testTrailingDotStrippedNilOnCleanPath() {
        XCTAssertNil(PathDetector.trailingDotStripped("/Users/dev/project/src/Foo.swift"))
    }

    func testTrailingDotStrippedNilOnAllDots() {
        // Guards the empty-after-stripping case explicitly rather than
        // returning "".
        XCTAssertNil(PathDetector.trailingDotStripped("..."))
    }

    func testTrailingDotStrippedStripsMultiple() {
        XCTAssertEqual(PathDetector.trailingDotStripped("src/a.swift.."), "src/a.swift")
    }

    // MARK: Task 2 fix round 1 — accented filenames

    func testAccentedFilenameIsOneToken() {
        // "open résumé.pdf now" — clickColumn 8 lands mid-token, on the 'u'
        // in "résumé". Accented letters must not split the token in two,
        // or the click would resolve to a fragment that isn't the real file.
        let result = PathDetector.extract(line: "open résumé.pdf now", clickColumn: 8, cwd: cwd)
        XCTAssertEqual(result?.path, "/Users/dev/project/résumé.pdf")
        XCTAssertNil(result?.line)
    }

    // MARK: resolve — the rows around the click, checked on disk

    func testAPathWrappedAtTheSpaceInItsNameIsFoundFromEitherRow() {
        // Claude Code wraps its own output: the space in "Mes Images" became
        // the row break, and the next row is indented like its paragraph.
        let folder = NSHomeDirectory() + "/Documents/Mes Images/export/2026-10-30"
        let rows = [
            "  Le rendu est dans ~/Documents/Mes",
            "  Images/export/2026-10-30/.",
            "",
        ]
        let exists: (String) -> Bool = { $0 == folder }
        let onSecondRow = PathDetector.resolve(rows: rows, clickRow: 1, clickColumn: 8, cwd: cwd, exists: exists)
        XCTAssertEqual(onSecondRow?.path, folder)
        let onFirstRow = PathDetector.resolve(rows: rows, clickRow: 0, clickColumn: 25, cwd: cwd, exists: exists)
        XCTAssertEqual(onFirstRow?.path, folder)
    }

    func testAPathLongerThanARowIsJoinedWithoutASpaceAndBeatsTheFolderItPassesThrough() {
        let file = "/Users/someone/projet/rendus/lot0/turntable/frame.png"
        let rows = ["  /Users/someone/projet/rendus/lot0/", "  turntable/frame.png:12"]
        let exists: (String) -> Bool = { $0 == file || $0 == "/Users/someone/projet/rendus/lot0" }
        let result = PathDetector.resolve(rows: rows, clickRow: 0, clickColumn: 10, cwd: cwd, exists: exists)
        XCTAssertEqual(result?.path, file)
        XCTAssertEqual(result?.line, 12)
    }

    func testANameWithSpacesOnOneRow() {
        let file = "/Users/someone/Desktop/Capture d’écran 2026-10-30 à 21.28.57.png"
        let line = "Voir (/Users/someone/Desktop/Capture d’écran 2026-10-30 à 21.28.57.png), puis"
        let result = PathDetector.resolve(rows: [line], clickRow: 0, clickColumn: 60, cwd: cwd,
                                          exists: { $0 == file })
        XCTAssertEqual(result?.path, file)
    }

    func testTheClickedTokenAloneStillResolvesWithItsLineAndWithoutTheSentenceDot() {
        let rows = ["The fix is in src/Foo.swift. Please check.", "Then (src/Bar.swift:3), done."]
        let exists: (String) -> Bool = {
            $0 == "/Users/dev/project/src/Foo.swift" || $0 == "/Users/dev/project/src/Bar.swift"
        }
        XCTAssertEqual(PathDetector.resolve(rows: rows, clickRow: 0, clickColumn: 18, cwd: cwd, exists: exists)?.path,
                       "/Users/dev/project/src/Foo.swift")
        let bar = PathDetector.resolve(rows: rows, clickRow: 1, clickColumn: 9, cwd: cwd, exists: exists)
        XCTAssertEqual(bar?.path, "/Users/dev/project/src/Bar.swift")
        XCTAssertEqual(bar?.line, 3)
    }

    func testNothingOnDiskOrABlankRowBetweenGivesNothing() {
        let rows = ["  see ~/Documents/Mes", "", "  Images/export/"]
        let folder = NSHomeDirectory() + "/Documents/Mes Images/export"
        XCTAssertNil(PathDetector.resolve(rows: rows, clickRow: 2, clickColumn: 4, cwd: cwd, exists: { $0 == folder }))
        XCTAssertNil(PathDetector.resolve(rows: rows, clickRow: 0, clickColumn: 5, cwd: cwd, exists: { _ in true }),
                     "a click on a space names nothing")
    }
}
