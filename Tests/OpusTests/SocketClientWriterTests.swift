import XCTest
@testable import Opus

final class SocketClientWriterTests: XCTestCase {
    override class func setUp() { signal(SIGPIPE, SIG_IGN) }

    private func makePair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    func testWritesReachTheOtherEnd() {
        let (a, b) = makePair()
        let writer = SocketClientWriter(fd: a, onFailure: { XCTFail("no failure expected") })
        writer.enqueue(Data("hello".utf8))
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(b, &buf, buf.count)   // blocks until the writer queue flushes
        XCTAssertEqual(n, 5)
        XCTAssertEqual(Array(buf[0..<5]), Array("hello".utf8))
        writer.shutdown(); close(b)
    }

    func testClosedPeerTriggersOnFailureWithoutCrashing() {
        let (a, b) = makePair()
        close(b)   // peer gone
        let failed = expectation(description: "onFailure")
        failed.assertForOverFulfill = false
        let writer = SocketClientWriter(fd: a, onFailure: { failed.fulfill() })
        // Two writes: first may succeed into the dead socket's buffer window,
        // the follow-up must surface EPIPE. Either way onFailure fires once+.
        writer.enqueue(Data(repeating: 0x41, count: 65536))
        writer.enqueue(Data(repeating: 0x42, count: 65536))
        wait(for: [failed], timeout: 2.0)
        writer.shutdown()
    }

    func testQueuedBacklogTripsCap() {
        let (a, _) = makePair()   // nobody reads b → kernel buffer fills, queue backs up
        let failed = expectation(description: "onFailure via cap")
        failed.assertForOverFulfill = false
        // Stall timeout way out of the picture — this test is specifically
        // about the enqueue-side backlog accounting, not the stall budget.
        let writer = SocketClientWriter(fd: a, stallTimeout: 30, onFailure: { failed.fulfill() })
        // pendingBytes is now updated synchronously in enqueue(), under
        // lock, before the chunk is ever handed to the write queue — so the
        // cap sees the REAL queued backlog of many small chunks, not just
        // whichever one happens to be mid-write. 128 KB x 40 = 5 MB total;
        // the 4 MB cap trips synchronously around the 33rd chunk
        // (32 x 128 KB == the cap exactly; the 33rd pushes it over).
        for _ in 0..<40 { writer.enqueue(Data(repeating: 0x43, count: 128 * 1024)) }
        wait(for: [failed], timeout: 5.0)
        writer.shutdown()
    }

    func testStalledPeerIsDroppedAfterStallTimeout() {
        let (a, _) = makePair()   // nobody reads → kernel buffer fills fast
        let failed = expectation(description: "onFailure via stall budget")
        failed.assertForOverFulfill = false
        let writer = SocketClientWriter(fd: a, stallTimeout: 0.2, onFailure: { failed.fulfill() })
        writer.enqueue(Data(repeating: 0x43, count: 256 * 1024))   // > kernel buf, < pendingCap
        wait(for: [failed], timeout: 5.0)
        writer.shutdown()
    }
}
