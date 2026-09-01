// KeychainSecretStoreTests — the only tests in this target that touch the
// real login Keychain, which is why they are opt-in.
//
// Every other secrets test runs against InMemorySecretStore. That fake
// honours SecretValueValidator and nothing else, so it agreed with the
// real store on the one dimension both were asked about (the 8 KB cap)
// while the real store silently truncated at 128 bytes. A fake can only
// disagree with reality where someone thought to look; this file is where
// someone looks.
//
// Enable with OPUS_KEYCHAIN_TESTS=1. Each test writes to a service name
// containing a fresh UUID, so it can never collide with, read, or delete
// a real secret, and removes what it wrote.

import XCTest
@testable import OpusSecretsKit

final class KeychainSecretStoreTests: XCTestCase {
    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPUS_KEYCHAIN_TESTS"] == "1",
            "set OPUS_KEYCHAIN_TESTS=1 to run the tests that write to the real Keychain"
        )
    }

    /// The regression this file exists for. `security add-generic-password
    /// -w` with no argument reads the value through readpassphrase(), whose
    /// buffer is _PASSWORD_LEN (128 bytes); the rest of the line is
    /// discarded. Because the confirmation line was truncated to the same
    /// 128 bytes it still matched, so the tool exited 0 and Opus reported
    /// success on a value it had just cut in half.
    func testValueLongerThan128BytesSurvivesTheRoundTrip() throws {
        try skipUnlessEnabled()
        let store = KeychainSecretStore(service: "opus-tests-\(UUID().uuidString)")
        // 300 covers the real offenders: OpenAI project keys (~164) and
        // service-account JSON blobs both clear 128 comfortably.
        let value = String(repeating: "k", count: 300)

        try store.put(name: "probe", value: value)
        defer { try? store.remove(name: "probe") }

        XCTAssertEqual(try store.value(for: "probe"), value)
    }

    /// The value reaches `security` inside a command line, so anything the
    /// tool's own argument parser could mistake for an option or a
    /// delimiter has to survive intact.
    func testValueWithShellAndOptionLookalikesSurvivesTheRoundTrip() throws {
        try skipUnlessEnabled()
        let store = KeychainSecretStore(service: "opus-tests-\(UUID().uuidString)")
        let value = #"sk-proj_a"b'c\d $(rm -rf /) ; | & -w --keychain"#

        try store.put(name: "probe", value: value)
        defer { try? store.remove(name: "probe") }

        XCTAssertEqual(try store.value(for: "probe"), value)
    }

    /// Ties the validator's printable-ASCII rule to the thing that forced
    /// it: the whole 0x20...0x7E range has to survive the real Keychain, or
    /// the rule is drawn in the wrong place.
    func testEveryPrintableASCIIByteSurvivesTheRoundTrip() throws {
        try skipUnlessEnabled()
        let store = KeychainSecretStore(service: "opus-tests-\(UUID().uuidString)")
        let printable = String(String.UnicodeScalarView((0x20...0x7E).map { Unicode.Scalar($0)! }))

        try store.put(name: "probe", value: printable)
        defer { try? store.remove(name: "probe") }

        XCTAssertEqual(try store.value(for: "probe"), printable)
    }

    /// Re-entering a secret that the old write path had already truncated
    /// has to replace it in full, not update the first 128 bytes of it.
    func testOverwritingAnExistingItemReplacesTheWholeValue() throws {
        try skipUnlessEnabled()
        let store = KeychainSecretStore(service: "opus-tests-\(UUID().uuidString)")
        let long = String(repeating: "z", count: 250)

        try store.put(name: "probe", value: "short")
        defer { try? store.remove(name: "probe") }
        try store.put(name: "probe", value: long)

        XCTAssertEqual(try store.value(for: "probe"), long)
    }
}
