import Foundation
import OpusScriptsKit

/// What a script is doing right now.
enum ScriptRunState: Equatable {
    case idle
    case running(since: Date)
    /// `code` is the exit status; `signal` is set instead when the process was
    /// killed. Stopping from the panel produces `signal: SIGTERM`, which the
    /// UI reports as "arrêté" rather than as a failure — the user asked for it.
    case finished(code: Int32, signal: Int32?, at: Date)

    var isRunning: Bool { if case .running = self { return true }; return false }
}

/// Owns the lifetime of every script Opus has launched.
///
/// One instance per script PATH: launching a script that is already running
/// is a stop, not a second copy. Two copies of the same background toggle is
/// never what anyone means, and the panel would have no way to show which of
/// them a stop button referred to.
///
/// Everything here is main-thread. Process output arrives on a background
/// queue and is hopped to main before touching any state, so the panel never
/// reads a half-written buffer.
final class ScriptRunner {
    static let shared = ScriptRunner()

    /// Raised whenever any script's state or output changes, so the panel can
    /// refresh without polling.
    static let didChangeNotification = Notification.Name("OpusScriptRunnerDidChange")

    private struct Run {
        let process: Process
        let started: Date
        var buffer: ScriptOutputBuffer
        /// Set when the panel asked for the stop, so an exit by SIGTERM reads
        /// as deliberate rather than as a crash.
        var stopRequested: Bool
    }

    private var runs: [String: Run] = [:]
    private var lastStates: [String: ScriptRunState] = [:]

    private init() {}

    // MARK: Reading state

    func state(of script: ScriptDefinition) -> ScriptRunState {
        if let run = runs[script.id] { return .running(since: run.started) }
        return lastStates[script.id] ?? .idle
    }

    func output(of script: ScriptDefinition) -> ScriptOutputBuffer {
        runs[script.id]?.buffer ?? finishedBuffers[script.id] ?? ScriptOutputBuffer()
    }

    var runningCount: Int { runs.count }

    private var finishedBuffers: [String: ScriptOutputBuffer] = [:]

    // MARK: Launching

    /// Starts the script, or stops it if it is already running. Returns a
    /// human-readable error when the launch itself fails, which the panel
    /// shows in red — a script that silently does nothing when clicked is the
    /// worst possible outcome here.
    @discardableResult
    func toggle(_ script: ScriptDefinition) -> String? {
        if runs[script.id] != nil {
            stop(script)
            return nil
        }
        return start(script)
    }

    @discardableResult
    private func start(_ script: ScriptDefinition) -> String? {
        let process = Process()
        // Through zsh -l rather than executing the file directly: a login
        // shell gives the script the same PATH and environment the owner gets in a
        // terminal, so a script that calls `gh` or `ffmpeg` works here exactly
        // as it does when he runs it himself. Executing the file directly
        // would hand it Opus's own launch environment, where those are absent.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellQuoted(script.url.path)]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr is merged into stdout on purpose: a script's error message is
        // the single most useful thing to show, and splitting the streams
        // would let it arrive out of order with the output it explains.
        process.standardError = pipe

        var buffer = ScriptOutputBuffer()
        buffer.clear()
        runs[script.id] = Run(process: process, started: Date(), buffer: buffer, stopRequested: false)
        finishedBuffers[script.id] = nil

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.appendOutput(chunk, to: script.id)
            }
        }

        process.terminationHandler = { [weak self] finished in
            // Tear the handler down from the same place that installed it, and
            // do it before hopping to main: leaving it attached keeps the pipe
            // alive and leaks a file descriptor per run.
            pipe.fileHandleForReading.readabilityHandler = nil
            let trailing = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let tail = trailing.isEmpty ? "" : String(decoding: trailing, as: UTF8.self)
            DispatchQueue.main.async {
                self?.handleTermination(of: script.id, process: finished, trailingOutput: tail)
            }
        }

        do {
            try process.run()
        } catch {
            runs[script.id] = nil
            let message = "lancement impossible : \(error.localizedDescription)"
            var failed = ScriptOutputBuffer()
            failed.append(message)
            finishedBuffers[script.id] = failed
            lastStates[script.id] = .finished(code: -1, signal: nil, at: Date())
            notifyChanged()
            return message
        }
        notifyChanged()
        return nil
    }

    func stop(_ script: ScriptDefinition) {
        guard var run = runs[script.id] else { return }
        run.stopRequested = true
        runs[script.id] = run
        // SIGTERM, not SIGKILL: a script gets the chance to clean up after
        // itself. Nothing here escalates to SIGKILL — a script that ignores
        // SIGTERM is doing so deliberately, and killing it from under its own
        // trap handler would defeat the reason it installed one.
        run.process.terminate()
    }

    /// Called when Opus is quitting. Background scripts are Opus's children:
    /// leaving them orphaned would strand processes the user has no way to
    /// find again, since the panel that knew about them is gone.
    func stopAll() {
        for run in runs.values where run.process.isRunning {
            run.process.terminate()
        }
    }

    // MARK: Internals

    private func appendOutput(_ chunk: String, to id: String) {
        guard var run = runs[id] else { return }
        run.buffer.append(ScriptOutputBuffer.stripAnsi(chunk))
        runs[id] = run
        notifyChanged()
    }

    private func handleTermination(of id: String, process: Process, trailingOutput: String) {
        guard let run = runs[id] else { return }
        var buffer = run.buffer
        if !trailingOutput.isEmpty {
            buffer.append(ScriptOutputBuffer.stripAnsi(trailingOutput))
        }
        finishedBuffers[id] = buffer
        runs[id] = nil

        let signal: Int32? = process.terminationReason == .uncaughtSignal
            ? process.terminationStatus
            : nil
        lastStates[id] = .finished(
            code: process.terminationStatus,
            signal: run.stopRequested ? SIGTERM : signal,
            at: Date()
        )
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Single-quote the path so a folder with a space or an apostrophe in its
    /// name cannot split into two arguments — or worse, run as a command.
    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
