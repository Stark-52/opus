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

    func testBackpressureCapTriggersFailure() {
        let (a, _) = makePair()   // nobody reads b → kernel buffer fills
        let failed = expectation(description: "onFailure via cap")
        failed.assertForOverFulfill = false
        let writer = SocketClientWriter(fd: a, onFailure: { failed.fulfill() })
        // Push well past the 4 MB pending cap while the socket back-pressures.
        //
        // Deviation from the brief's 80x128KB loop (see task-4-report.md):
        // macOS's default AF_UNIX buffers (net.local.stream.{send,recv}space
        // = 8 KB each) are far smaller than a single 128 KB chunk. With
        // nobody ever draining `b`, the writer's *first* enqueue() already
        // parks forever in the EAGAIN retry loop, and because the writer
        // queue is serial, no later enqueue() call ever runs far enough to
        // add its own bytes to pendingBytes — so 80 small chunks never
        // accumulate past the cap; the loop just times out. A single chunk
        // whose own size already exceeds the cap trips the guard
        // deterministically, before any write(2) is attempted.
        writer.enqueue(Data(repeating: 0x43, count: SocketClientWriter.pendingCap + 64 * 1024))
        wait(for: [failed], timeout: 5.0)
        writer.shutdown()
    }
}
