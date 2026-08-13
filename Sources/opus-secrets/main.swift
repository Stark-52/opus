// opus-secrets — one binary, two audiences.
//
//   Human:   put / get / ls / rm / run
//   Claude Code: hook-pre / hook-post / hook-session
//
// The hook modes are the reason this is a compiled binary and not a shell
// script: PreToolUse and PostToolUse fire on EVERY tool call, so the cost
// of the fast path is the cost of the feature. A Swift binary exits in
// single-digit milliseconds; bash plus a `security` call would be five to
// ten times that.
//
// A hook must never write anything to stdout except its JSON response, and
// must never exit non-zero on an internal problem: either would surface to
// the user as a broken tool call. Every failure path here exits 0 silently
// and lets the original input through.

import Foundation
import OpusSecretsKit

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func emit(_ data: Data?) -> Never {
    if let data { FileHandle.standardOutput.write(data) }
    exit(0)
}

let store = KeychainSecretStore()
let usage = SessionUsage()
let runner = HookRunner(store: store, usage: usage)

switch arguments.first {

case "hook-pre":
    // Read the whole payload, decode it as UTF-8, then gate on a plain
    // substring search BEFORE any JSON parsing. Braces are not escaped in
    // JSON, so searching the decoded text this way is valid and still
    // skips a JSON parse on the common (no-placeholder) path — decoding
    // costs far less than JSONSerialization does.
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: raw, encoding: .utf8),
          text.contains(PlaceholderParser.marker)
    else { exit(0) }
    emit(runner.runPre(input: raw))

case "hook-post":
    emit(runner.runPost(input: FileHandle.standardInput.readDataToEndOfFile()))

case "hook-session":
    emit(runner.runSessionStart(input: FileHandle.standardInput.readDataToEndOfFile()))

case "put":
    guard arguments.count >= 2 else { fail("usage: opus-secrets put <nom>   (valeur sur stdin)") }
    let name = arguments[1]
    guard SecretName.isValid(name) else {
        fail("nom invalide : \(name)\nattendu : \(SecretName.grammar)")
    }
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let value = (String(data: raw, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { fail("valeur vide sur stdin") }
    do {
        try store.put(name: name, value: value)
        print("rangé : \(name) (\(value.count) caractères)")
        if SecretExtractor.isShellHostile(value) {
            print("attention : cette valeur contient des caractères que le shell interprète.")
            print("            préférer « opus-secrets run \(name)=VAR -- commande ».")
        }
        if value.count < SecretRedactor.minimumRedactableLength {
            print("attention : trop courte pour être couverte par la redaction automatique.")
        }
    } catch {
        fail("\(error)")
    }
    exit(0)

case "get":
    // Deliberately present, deliberately noisy. Piping is the supported
    // use; printing to a terminal is what puts a value on screen.
    guard arguments.count >= 2 else { fail("usage: opus-secrets get <nom>") }
    do {
        let value = try store.value(for: arguments[1])
        FileHandle.standardOutput.write(Data(value.utf8))
        if isatty(FileHandle.standardOutput.fileDescriptor) == 1 {
            FileHandle.standardError.write(Data("\n(valeur affichée sur un terminal : préférer un pipe)\n".utf8))
        }
    } catch {
        fail("\(error)")
    }
    exit(0)

case "ls":
    do {
        let names = try store.names()
        print(names.isEmpty ? "(aucun)" : names.joined(separator: "\n"))
    } catch {
        // Never report a failed read as an empty store: `ls` is the command
        // you run to find out what is in there, and "(aucun)" on a locked
        // Keychain is a lie that sends you looking in the wrong place.
        fail("\(error)")
    }
    exit(0)

case "rm":
    guard arguments.count >= 2 else { fail("usage: opus-secrets rm <nom>") }
    do {
        try store.remove(name: arguments[1])
        print("supprimé : \(arguments[1])")
    } catch {
        fail("\(error)")
    }
    exit(0)

case "run":
    // opus-secrets run name=VAR [name2=VAR2 ...] -- command args...
    guard let separator = arguments.firstIndex(of: "--"), separator > 1 else {
        fail("usage: opus-secrets run <nom>=<VAR> [...] -- <commande>")
    }
    let bindings = arguments[1..<separator]
    let command = Array(arguments[(separator + 1)...])
    guard let executable = command.first else { fail("aucune commande après --") }

    var environment = ProcessInfo.processInfo.environment
    for binding in bindings {
        let parts = binding.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("liaison invalide : \(binding)") }
        do {
            environment[parts[1]] = try store.value(for: parts[0])
        } catch {
            // Same reasoning as get/ls/rm above: `try?` would report a
            // locked Keychain identically to a plain typo ("introuvable"),
            // which is a lie when the real problem is that nothing at all
            // could be read.
            fail("\(error)")
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + command.dropFirst()
    process.environment = environment
    do { try process.run() } catch { fail("échec du lancement : \(error)") }
    process.waitUntilExit()
    exit(process.terminationStatus)

default:
    print("""
    opus-secrets — passe-plat de secrets entre the owner et Claude Code.

      put <nom>              range la valeur lue sur stdin
      get <nom>              ressort la valeur (à piper, pas à afficher)
      ls                     liste les noms rangés
      rm <nom>               supprime
      run <nom>=<VAR> -- cmd exécute cmd avec VAR peuplée

    Dans une commande Bash, Claude écrit {{secret:<nom>}} et la valeur est
    substituée à l'exécution, sans jamais entrer dans son contexte.
    """)
    exit(arguments.isEmpty ? 0 : 1)
}
