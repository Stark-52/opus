import XCTest
import Darwin
@testable import Opus
@testable import OpusBridgeKit

/// The bridge socket for real: one request line in, the handler's messages
/// out in order, and the connection closed after the final one.
final class BridgeServerTests: XCTestCase {
    private func socketPath() -> String {
        NSTemporaryDirectory() + "obt-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Sends `request` and reads every line until Opus closes the connection.
    private func exchange(_ path: String, _ request: Data) -> [Data] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                _ = strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, dest.count - 1)
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard ok else { return [] }
        request.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            all.append(contentsOf: buffer[0..<n])
        }
        return all.split(separator: 0x0A).map { Data($0) }
    }

    func testOneRequestInTheMessagesOutThenTheConnectionCloses() {
        let path = socketPath()
        let server = BridgeServer(path: path) { request, reply in
            reply(BridgeMessage(kind: .accepted, session: "s1"))
            reply(BridgeMessage(kind: .done, session: "s1", reply: "écho : \(request.task ?? "")"))
            reply(BridgeMessage(kind: .done, session: "s1", reply: "jamais envoyé"))
        }
        server.start()
        defer { server.stop() }

        let finished = expectation(description: "exchange")
        var lines: [Data] = []
        DispatchQueue.global().async {
            lines = self.exchange(path, BridgeWire.line(BridgeRequest(op: .ask, task: "bonjour\nà toi")))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        let messages = lines.compactMap { BridgeWire.decode(BridgeMessage.self, from: $0) }
        XCTAssertEqual(messages, [
            BridgeMessage(kind: .accepted, session: "s1"),
            BridgeMessage(kind: .done, session: "s1", reply: "écho : bonjour\nà toi"),
        ])
    }

    func testAnUnreadableRequestGetsAnError() {
        let path = socketPath()
        let server = BridgeServer(path: path) { _, reply in reply(BridgeMessage(kind: .done)) }
        server.start()
        defer { server.stop() }

        let finished = expectation(description: "exchange")
        var lines: [Data] = []
        DispatchQueue.global().async {
            lines = self.exchange(path, Data("pas du json\n".utf8))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(lines.compactMap { BridgeWire.decode(BridgeMessage.self, from: $0) }.map(\.kind), [.error])
    }

    func testOnlyTheOwnerMayConnect() throws {
        let path = socketPath()
        let server = BridgeServer(path: path) { _, _ in }
        server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
