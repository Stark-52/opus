// SecretStore — the Keychain, behind a protocol so every other unit in
// this module can be tested without touching the real Keychain.
//
// Why the real implementation is split across two mechanisms:
//
//   names()  uses SecItemCopyMatching with kSecReturnAttributes and NO
//            kSecReturnData. Attribute-only queries never consult the
//            item's access control list, so enumerating is fast and can
//            never raise an authorization prompt.
//
//   everything else shells out to /usr/bin/security, deliberately. Items
//            created by `security add-generic-password` carry an ACL
//            naming that tool; creating them through SecItemAdd instead
//            would produce items restricted to whichever binary called
//            it, and the existing ~/bin/secret script would stop being
//            able to read them. One write path keeps the two compatible.
//
// The value is passed to `security` on STDIN, twice (the tool prompts for
// the password then for a confirmation). It is never placed in argv,
// where `ps` would expose it for the lifetime of the call.

import Foundation
import Security

public enum SecretStoreError: Error, Equatable {
    case notFound(String)
    case invalidName(String)
    case invalidValue(String)
    case commandFailed(String)
}

public protocol SecretStore {
    func names() throws -> [String]
    func value(for name: String) throws -> String
    func put(name: String, value: String) throws
    func remove(name: String) throws
}

// SecretValueValidator — the door both stores put a value through, kept
// as one piece of code so the fake and the real Keychain store can never
// diverge on what they accept.
public enum SecretValueValidator {
    /// Same ceiling as SecretExtractor.maximumBlobBytes, deliberately: the
    /// panel and the store agree on one limit. The value is fed to
    /// `security` twice, so this caps stdin at 16 KB, comfortably under a
    /// pipe's default capacity — which is what keeps `run`'s write-then-read
    /// ordering from being able to stall.
    public static let maximumValueBytes = 8 * 1024

    static func validate(name: String, value: String) throws {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        // `security -w` reads the value line by line, so a newline would
        // truncate it and desynchronise the confirmation prompt. Refuse it
        // here rather than let `security` fail with "passwords don't match".
        //
        // Byte-level on purpose. Swift groups CR+LF into ONE extended
        // grapheme cluster, so `value.contains("\n")` is FALSE for a CRLF
        // string even though its UTF-8 carries 0x0A. Verified:
        // "a\r\nb".contains("\n") == false, "a\r\nb".utf8.contains(0x0A) == true.
        // `security` reads the value line by line and sees the bytes, not
        // Swift's graphemes, so the bytes are what must be checked.
        guard !value.utf8.contains(0x0A), !value.utf8.contains(0x0D) else {
            throw SecretStoreError.invalidValue(
                "valeur multi-ligne : le Trousseau est mono-ligne ici. Une clé PEM (.p8) reste dans un fichier."
            )
        }
        guard value.utf8.count <= maximumValueBytes else {
            throw SecretStoreError.invalidValue(
                "valeur trop longue (\(value.utf8.count) octets, maximum \(maximumValueBytes))"
            )
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private var storage: [String: String]

    public init(_ seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func names() throws -> [String] { storage.keys.sorted() }

    public func value(for name: String) throws -> String {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        guard let v = storage[name] else { throw SecretStoreError.notFound(name) }
        return v
    }

    public func put(name: String, value: String) throws {
        try SecretValueValidator.validate(name: name, value: value)
        storage[name] = value
    }

    public func remove(name: String) throws {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        guard storage.removeValue(forKey: name) != nil else { throw SecretStoreError.notFound(name) }
    }
}

public final class KeychainSecretStore: SecretStore {
    private let service: String
    private static let securityPath = "/usr/bin/security"

    /// Exit status `security` uses for "the specified item could not be
    /// found in the keychain". Every other non-zero status (locked
    /// keychain, denied authorization, malformed request, ...) is a real
    /// failure and must not be reported to the caller as a plain miss.
    private static let itemNotFoundStatus: Int32 = 44

    public init(service: String = "claude-secrets") {
        self.service = service
    }

    public func names() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw SecretStoreError.commandFailed("SecItemCopyMatching status \(status)")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func value(for name: String) throws -> String {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        let (status, out, err) = Self.run(
            arguments: ["find-generic-password", "-s", service, "-a", name, "-w"],
            stdin: nil
        )
        if status == 0 {
            // `security -w` terminates its output with a newline that is
            // not part of the stored value.
            return out.hasSuffix("\n") ? String(out.dropLast()) : out
        }
        if status == Self.itemNotFoundStatus { throw SecretStoreError.notFound(name) }
        throw SecretStoreError.commandFailed(err)
    }

    public func put(name: String, value: String) throws {
        try SecretValueValidator.validate(name: name, value: value)
        // -U updates in place when the item already exists. -w with no
        // argument reads the value from stdin; the tool asks twice, so the
        // value is fed twice.
        let (status, _, err) = Self.run(
            arguments: ["add-generic-password", "-U", "-s", service, "-a", name, "-w"],
            stdin: value + "\n" + value + "\n"
        )
        guard status == 0 else { throw SecretStoreError.commandFailed(err) }
    }

    public func remove(name: String) throws {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        let (status, _, err) = Self.run(
            arguments: ["delete-generic-password", "-s", service, "-a", name],
            stdin: nil
        )
        if status == 0 { return }
        if status == Self.itemNotFoundStatus { throw SecretStoreError.notFound(name) }
        throw SecretStoreError.commandFailed(err)
    }

    private static func run(arguments: [String], stdin: String?) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do { try process.run() } catch { return (-1, "", "\(error)") }

        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
