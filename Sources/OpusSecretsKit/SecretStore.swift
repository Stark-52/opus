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
// Writes go through `security -i`, the tool's interactive mode: the whole
// add-generic-password line arrives on STDIN, so the value is still never
// in argv, where `ps` would expose it for the lifetime of the call. It
// travels as hex through `-X` rather than as the answer to `-w`'s prompt.
//
// The prompt is what forced that. `-w` with no argument reads its answer
// through readpassphrase(), whose buffer is _PASSWORD_LEN — 128 bytes —
// and the rest of the line is discarded. The confirmation line was cut at
// the same 128 bytes, so the two still matched, so `security` exited 0 and
// this store reported success on a value it had just truncated. Every
// credential longer than 128 bytes (an OpenAI project key runs ~164) was
// stored broken, and nothing anywhere said so. `-X` takes the bytes as an
// argument and never prompts, so there is no buffer to overrun.

import Foundation
import Security

public enum SecretStoreError: Error, Equatable {
    case notFound(String)
    case invalidName(String)
    case invalidValue(String)
    case commandFailed(String)
}

extension SecretStoreError: CustomStringConvertible {
    /// The CLI prints these straight to the user, so they are sentences, not
    /// debug output. `commandFailed` carries `security`'s own stderr, which
    /// cannot contain a value: the read command never obtained one, and the
    /// write command receives the value on stdin rather than in argv.
    public var description: String {
        switch self {
        case .notFound(let name):
            return "secret « \(name) » introuvable"
        case .invalidName(let name):
            return "nom invalide : \(name) (attendu : \(SecretName.grammar))"
        case .invalidValue(let reason):
            return reason
        case .commandFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Trousseau inaccessible"
                : "Trousseau inaccessible : \(trimmed)"
        }
    }
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
    /// panel and the store agree on one limit. The value reaches `security`
    /// hex-encoded, so this caps stdin at 16 KB, comfortably under a pipe's
    /// default capacity — which is what keeps `run`'s write-then-read
    /// ordering from being able to stall.
    ///
    /// This is the store's OWN limit, not the tool's. It was once both, and
    /// the pair silently disagreed: this said 8 KB while the write path cut
    /// at 128. Anything that changes how a value reaches `security` has to
    /// be measured against a real Keychain, not against this constant —
    /// KeychainSecretStoreTests is where that measurement lives.
    public static let maximumValueBytes = 8 * 1024

    static func validate(name: String, value: String) throws {
        guard SecretName.isValid(name) else { throw SecretStoreError.invalidName(name) }
        // Refused on the READ side now, not the write side: `-X` carries a
        // newline through storage without complaint, but
        // `find-generic-password -w` prints the value as hex instead of as
        // itself as soon as it holds a byte outside printable ASCII —
        // verified with 0x610a62, which reads back as the four characters
        // "610a62". A value this store cannot hand back unchanged has no
        // business going in.
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
        // Everything else outside printable ASCII, for the same read-side
        // reason as the newline above. Measured boundary: 0x20 and 0x7E read
        // back as themselves, 0x1F, 0x7F, 0x80 and a UTF-8 e-acute all read
        // back as hex digits.
        //
        // Refused rather than decoded, because decoding is not merely harder
        // but destructive: `-w` renders the literal value "610a" and the
        // value "A\tBC" as the same shape, plain hex digits, so a decoder
        // cannot tell a hex-encoded control byte from a credential that
        // happens to be hex. Several real secrets ARE pure hex. Refusing
        // costs the rare accented passphrase; decoding would corrupt tokens
        // silently, which is the failure this whole file just came back from.
        if let offender = value.utf8.first(where: { $0 < 0x20 || $0 > 0x7E }) {
            throw SecretStoreError.invalidValue(
                "octet hors ASCII imprimable (0x\(String(format: "%02x", offender))) : le Trousseau relirait la valeur en hexadécimal au lieu d'elle-même."
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
        let (status, _, err) = Self.run(arguments: ["-i"], stdin: putCommand(name: name, value: value))
        guard status == 0 else { throw SecretStoreError.commandFailed(err) }
    }

    /// The single line handed to `security -i`. `-U` updates in place when
    /// the item already exists, which is what lets a truncated secret be
    /// repaired by re-entering it.
    ///
    /// Interactive mode tokenises this line itself, so a value holding a
    /// space or a quote would need quoting — and a quoting bug here
    /// corrupts a credential without a word. Hex deletes the question
    /// rather than answering it: `-X` accepts [0-9a-f] and nothing else,
    /// `service` is a constant this type owns, and `name` has already been
    /// through SecretName's grammar, so no field on this line can carry a
    /// character the tokeniser reacts to.
    func putCommand(name: String, value: String) -> String {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U -s \(service) -a \(name) -X \(hex)\n"
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
