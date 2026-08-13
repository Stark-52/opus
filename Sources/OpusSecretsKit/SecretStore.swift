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
    case commandFailed(String)
}

public protocol SecretStore {
    func names() throws -> [String]
    func value(for name: String) throws -> String
    func put(name: String, value: String) throws
    func remove(name: String) throws
}

public final class InMemorySecretStore: SecretStore {
    private var storage: [String: String]

    public init(_ seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func names() throws -> [String] { storage.keys.sorted() }

    public func value(for name: String) throws -> String {
        guard let v = storage[name] else { throw SecretStoreError.notFound(name) }
        return v
    }

    public func put(name: String, value: String) throws {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        storage[name] = value
    }

    public func remove(name: String) throws {
        guard storage.removeValue(forKey: name) != nil else { throw SecretStoreError.notFound(name) }
    }
}

public final class KeychainSecretStore: SecretStore {
    private let service: String
    private static let securityPath = "/usr/bin/security"

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
        let (status, out, _) = Self.run(
            arguments: ["find-generic-password", "-s", service, "-a", name, "-w"],
            stdin: nil
        )
        guard status == 0 else { throw SecretStoreError.notFound(name) }
        // `security -w` terminates its output with a newline that is not
        // part of the stored value.
        return out.hasSuffix("\n") ? String(out.dropLast()) : out
    }

    public func put(name: String, value: String) throws {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
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
        let (status, _, _) = Self.run(
            arguments: ["delete-generic-password", "-s", service, "-a", name],
            stdin: nil
        )
        guard status == 0 else { throw SecretStoreError.notFound(name) }
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
