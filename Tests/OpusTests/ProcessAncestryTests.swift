import XCTest
@testable import OpusArtifactsKit

/// Attribution: given the pid of the `opus-attach` process a hook ran, work
/// out which pane it belongs to. Nothing in a hook payload names a pane, and
/// after a `/resume` the session id no longer matches what Opus spawned the
/// pane with, so walking the process tree is the only thing left that still
/// tells the truth.
///
/// The parent lookup is injected, so the whole thing is testable against a
/// made-up tree instead of against whatever happens to be running.
final class ProcessAncestryTests: XCTestCase {

    /// child -> parent, the shape `sysctl` gives us one hop at a time.
    private func tree(_ pairs: [Int32: Int32]) -> (Int32) -> Int32? {
        { pairs[$0] }
    }

    func testDirectChildOfAKnownShell() {
        let owner = ProcessAncestry.owner(
            of: 100, among: [42], parentOf: tree([100: 42, 42: 1]))
        XCTAssertEqual(owner, 42)
    }

    func testWalksSeveralHopsUp() {
        // opus-attach -> claude -> shell. The real shape.
        let owner = ProcessAncestry.owner(
            of: 300, among: [42], parentOf: tree([300: 200, 200: 100, 100: 42, 42: 1]))
        XCTAssertEqual(owner, 42)
    }

    func testPicksTheRightShellAmongSeveral() {
        // Two tabs, two panes. Attributing to the wrong one is the silent
        // failure this whole mechanism exists to prevent.
        let owner = ProcessAncestry.owner(
            of: 300, among: [42, 77],
            parentOf: tree([300: 200, 200: 77, 77: 1, 42: 1]))
        XCTAssertEqual(owner, 77)
    }

    func testUnrelatedProcessBelongsToNoPane() {
        XCTAssertNil(ProcessAncestry.owner(
            of: 999, among: [42], parentOf: tree([999: 1])))
    }

    func testStopsAtPidOneRatherThanRunningForever() {
        XCTAssertNil(ProcessAncestry.owner(
            of: 5, among: [42], parentOf: tree([5: 4, 4: 3, 3: 2, 2: 1])))
    }

    func testSurvivesACycleInTheTree() {
        // A parent chain should never loop, but a bounded walk costs nothing
        // and a hang inside a hook handler would freeze the app.
        XCTAssertNil(ProcessAncestry.owner(
            of: 7, among: [42], parentOf: tree([7: 8, 8: 7])))
    }

    func testAProcessThatIsItselfTheShell() {
        XCTAssertEqual(ProcessAncestry.owner(
            of: 42, among: [42], parentOf: tree([42: 1])), 42)
    }

    func testNoKnownShellsMeansNoOwner() {
        XCTAssertNil(ProcessAncestry.owner(
            of: 100, among: [], parentOf: tree([100: 42, 42: 1])))
    }

    func testMissingParentEndsTheWalkCleanly() {
        // sysctl can fail, or the parent can exit mid-walk.
        XCTAssertNil(ProcessAncestry.owner(
            of: 100, among: [42], parentOf: { _ in nil }))
    }
}
