import XCTest
@testable import OpusSecretsKit

/// These tests prove CommandSubstitutionRewriter's output is safe by
/// actually running it through a real shell, not by reasoning about the
/// shape of the string. Reasoning about quoting is exactly what missed the
/// pending-escape bug this file exists to guard against: a placeholder
/// immediately preceded by a backslash, with zero characters in between,
/// was rewritten in a way that either ran the substitution unquoted or
/// never ran it at all — see the two REFUSED tests below for the
/// mechanism, and the file's own commit history for how it was found.
///
/// A stub binary stands in for `opus-secrets`: called as `<stub> get
/// <name>`, it prints a fixed, recognisable sentinel for that name to
/// stdout. The whole rewritten command is then handed to `/bin/bash -c`
/// and its REAL stdout is what gets asserted on.
final class CommandSubstitutionRewriterTests: XCTestCase {
    private var stubPath: String!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-secrets-rewriter-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let stub = tempDir.appendingPathComponent("stub-opus-secrets")
        let script = """
        #!/bin/sh
        if [ "$1" = "get" ]; then
            printf '%s' "SENTINEL-$2"
            exit 0
        fi
        exit 1
        """
        try! script.write(to: stub, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        stubPath = stub.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Runs `command` through a real `/bin/bash -c` and returns stdout.
    private func runInBash(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func rewrite(_ command: String) -> CommandSubstitutionRewrite {
        CommandSubstitutionRewriter.rewrite(command, binaryPath: stubPath)
    }

    // MARK: The pending-escape bug — refused, not miscompiled

    func testABackslashImmediatelyBeforeAPlaceholderOutsideQuotesIsRefused() {
        // printf %s \{{secret:k}} — zero gap. Rewritten as an ordinary
        // outside-quotes splice, the backslash would consume the FIRST
        // character we insert (our own opening "), running the
        // substitution unquoted and leaving the trailing " dangling.
        guard case .refusedPendingEscape(let name) = rewrite("printf %s \\{{secret:k}}") else {
            return XCTFail("expected refusedPendingEscape")
        }
        XCTAssertEqual(name, "k")
    }

    func testABackslashImmediatelyBeforeAPlaceholderInsideDoubleQuotesIsRefused() {
        // echo "abc\{{secret:k}}" — inside double quotes, \$ is POSIX's own
        // escape-the-dollar. Rewritten as an ordinary double-quotes splice
        // (which starts with $), the substitution would never run at all:
        // the literal text "$(<path> get k)" would reach the argument,
        // unexecuted — the same "literal string sent as if it were the
        // credential" outcome the single-quote refusal exists to prevent.
        guard case .refusedPendingEscape(let name) = rewrite("echo \"abc\\{{secret:k}}\"") else {
            return XCTFail("expected refusedPendingEscape")
        }
        XCTAssertEqual(name, "k")
    }

    func testASingleQuoteContextWinsOverAPendingEscape() {
        // echo '\{{secret:k}}' — backslash has no meaning at all inside
        // single quotes, so this must be reported as the single-quote
        // refusal, not the pending-escape one: there is nothing "pending"
        // in a context where backslash is inert.
        guard case .refusedInsideSingleQuotes(let name) = rewrite("echo '\\{{secret:k}}'") else {
            return XCTFail("expected refusedInsideSingleQuotes")
        }
        XCTAssertEqual(name, "k")
    }

    // MARK: The fix must not over-refuse

    func testAnEvenNumberOfBackslashesIsNotRefusedAndActuallyRuns() throws {
        // echo \\{{secret:k}} — the first backslash escapes the second, so
        // the boundary at the placeholder is clean: no PENDING escape.
        // Proved by actually running it: the resolved sentinel must appear
        // in real bash's stdout, glued to one literal backslash.
        guard case .rewritten(let command, _) = rewrite("echo \\\\{{secret:k}}") else {
            return XCTFail("expected a rewrite")
        }
        // `echo` appends its own trailing newline; every raw-stdout
        // assertion in this file accounts for it explicitly rather than
        // trimming, so a doubled or missing newline elsewhere cannot hide.
        let output = try runInBash(command)
        XCTAssertEqual(output, "\\SENTINEL-k\n")
    }

    func testASpacedPlaceholderOutsideQuotesStillRunsCorrectlyInRealBash() throws {
        guard case .rewritten(let command, _) = rewrite("echo {{secret:k}}") else {
            return XCTFail("expected a rewrite")
        }
        let output = try runInBash(command)
        XCTAssertEqual(output, "SENTINEL-k\n")
    }

    func testASpacedPlaceholderInsideDoubleQuotesStillRunsCorrectlyInRealBash() throws {
        // A backslash followed by a SPACE inside double quotes has no
        // escaping effect on anything past the space (space is not one of
        // POSIX's escapable characters there), so the placeholder itself
        // sits at a clean boundary and must still be rewritten and run.
        guard case .rewritten(let command, _) = rewrite("echo \"x \\ {{secret:k}}\"") else {
            return XCTFail("expected a rewrite")
        }
        let output = try runInBash(command)
        XCTAssertEqual(output, "x \\ SENTINEL-k\n")
    }

    func testAPlaceholderContainingASpaceInTheResolvedValueStaysOneArgumentOutsideQuotes() throws {
        // The whole reason the outside-quotes branch adds its OWN double
        // quotes: unquoted $(...) word-splits a multi-word value into
        // several arguments. Prove the quoting actually prevents that by
        // running a stub that returns a value with an embedded space,
        // handing the BARE substitution (not a whole "echo ..." command,
        // which would itself add an extra word) to `set --`, and checking
        // exactly one positional parameter landed.
        let spaced = tempDir.appendingPathComponent("stub-spaced")
        try! "#!/bin/sh\nprintf '%s' 'two words'\n".write(to: spaced, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spaced.path)

        guard case .rewritten(let substitution, _) = CommandSubstitutionRewriter.rewrite(
            "{{secret:k}}", binaryPath: spaced.path
        ) else {
            return XCTFail("expected a rewrite")
        }
        let output = try runInBash("set -- \(substitution); echo $#")
        XCTAssertEqual(output, "1\n", "a quoted substitution must land as exactly one shell word")
    }

    // MARK: Two placeholders, mixed contexts, both real

    func testTwoPlaceholdersInDifferentContextsBothResolveInRealBash() throws {
        guard case .rewritten(let command, let consumed) = rewrite("echo {{secret:a}} && echo \"X: {{secret:b}}\"") else {
            return XCTFail("expected a rewrite")
        }
        XCTAssertEqual(consumed, 2, "two distinct names, both spliced")
        let output = try runInBash(command)
        XCTAssertEqual(output, "SENTINEL-a\nX: SENTINEL-b\n")
    }

    func testTheSameNameReferencedTwiceIsNotOverRefusedAndCountsAsOneConsumedName() throws {
        // `consumed` is a count of DISTINCT names, not raw occurrences —
        // this is the case that would matter if it were counted as raw
        // occurrences instead: runPre compares it against the number of
        // DISTINCT names it requested, and a legitimate command referencing
        // the same secret twice must not trip that check.
        guard case .rewritten(let command, let consumed) = rewrite("echo {{secret:k}} {{secret:k}}") else {
            return XCTFail("expected a rewrite")
        }
        XCTAssertEqual(consumed, 1)
        let output = try runInBash(command)
        XCTAssertEqual(output, "SENTINEL-k SENTINEL-k\n")
    }

    // MARK: Heredoc bodies — refused, not silently made literal
    //
    // Verified through real bash before this refusal existed: a heredoc
    // body reads to ShellQuoteScanner as plain "outside quotes" (it knows
    // nothing about `<<` redirection), so `cat > .env <<'EOF'` /
    // `API_KEY={{secret:k}}` / `EOF` wrote the LITERAL string
    // `API_KEY="$(<path> get k)"` into the file — no refusal, nothing
    // wrong-looking in the output, and a later `source .env` or deploy step
    // would send that text as the credential.

    func testAPlaceholderInsideASingleQuotedDelimiterHeredocBodyIsRefused() {
        let command = "cat > .env <<'EOF'\nAPI_KEY={{secret:k}}\nEOF\n"
        guard case .refusedInsideHeredoc(let name) = rewrite(command) else {
            return XCTFail("expected refusedInsideHeredoc")
        }
        XCTAssertEqual(name, "k")
    }

    func testAPlaceholderInsideADoubleQuotedDelimiterHeredocBodyIsRefused() {
        let command = "cat > .env <<\"EOF\"\nAPI_KEY={{secret:k}}\nEOF\n"
        guard case .refusedInsideHeredoc(let name) = rewrite(command) else {
            return XCTFail("expected refusedInsideHeredoc")
        }
        XCTAssertEqual(name, "k")
    }

    func testAPlaceholderInsideAnUnquotedDelimiterHeredocBodyIsRefused() {
        // An unquoted delimiter DOES let the shell run $(...) inside the
        // body, but this rewriter also adds its OWN double quotes in the
        // outside-quotes branch, and those have no syntactic meaning inside
        // a heredoc body — they would land as two literal `"` characters in
        // the file rather than as quoting. Refused for the same reason as
        // the quoted-delimiter cases, not treated as a safe special case.
        let command = "cat > .env <<EOF\nAPI_KEY={{secret:k}}\nEOF\n"
        guard case .refusedInsideHeredoc(let name) = rewrite(command) else {
            return XCTFail("expected refusedInsideHeredoc")
        }
        XCTAssertEqual(name, "k")
    }

    func testADashedHeredocWithATabIndentedBodyIsAlsoRefused() {
        let command = "cat > .env <<-EOF\n\tAPI_KEY={{secret:k}}\nEOF\n"
        guard case .refusedInsideHeredoc(let name) = rewrite(command) else {
            return XCTFail("expected refusedInsideHeredoc")
        }
        XCTAssertEqual(name, "k")
    }

    func testAHereStringStillWorksAndIsNotRefused() throws {
        // <<< is a here-string, not a heredoc — the placeholder here sits
        // in ordinary double quotes and must be rewritten and run exactly
        // as it would be anywhere else.
        guard case .rewritten(let command, _) = rewrite("cat <<< \"{{secret:k}}\"") else {
            return XCTFail("expected a rewrite, not a refusal")
        }
        let output = try runInBash(command)
        XCTAssertEqual(output, "SENTINEL-k\n")
    }

    func testAPlaceholderAfterAHeredocHasClosedIsStillRewrittenNormally() throws {
        let command = "cat <<'EOF'\nbody\nEOF\necho {{secret:k}}"
        guard case .rewritten(let rewritten, _) = rewrite(command) else {
            return XCTFail("expected a rewrite, not a refusal")
        }
        let output = try runInBash(rewritten)
        XCTAssertEqual(output, "body\nSENTINEL-k\n")
    }
}
