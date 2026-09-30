import Foundation
import NowCore

/// Spawns the join-hook command in the user's login shell. Meeting data is
/// passed through the environment (see `JoinHook.environment`); the command
/// string is executed verbatim and never receives interpolated calendar
/// content, so untrusted titles or links cannot inject shell syntax. The run
/// is bounded (`JoinHook.timeoutSeconds`, then SIGTERM and SIGKILL) and only a
/// short stderr excerpt survives for the Settings history.
enum JoinHookRunner {
    /// Serializes watchdog work; the process itself runs concurrently.
    private static let queue = DispatchQueue(label: "local.tboch.now.join-hook", qos: .utility)

    /// State shared between the pipe reader, termination handler and timeout
    /// watchdog — all unsynchronized queues. Guarded like
    /// `CalendarTransportDelegate`; the box crosses those boundaries, the
    /// lock keeps the races out.
    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var finished = false
        private var killed = false
        private var collected = Data()
        /// Past this the excerpt has more than it can show; stop reading and
        /// close the pipe so a spamming child dies on SIGPIPE instead of
        /// buffering unbounded output.
        private let stderrLimit = 8 * 1024

        func install(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
        }

        func appendStderr(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard collected.count < stderrLimit else { return }
            collected.append(data.prefix(stderrLimit - collected.count))
        }

        var stderrOverflowing: Bool {
            lock.lock(); defer { lock.unlock() }
            return collected.count >= stderrLimit
        }

        var stderr: String? {
            lock.lock(); defer { lock.unlock() }
            return String(data: collected, encoding: .utf8)
        }

        /// First caller wins; later completions (watchdog vs. termination) are dropped.
        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }

        /// Terminates a still-running child. Returns false when it already
        /// finished on its own.
        @discardableResult
        func terminateIfRunning() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let process, process.isRunning, !finished else { return false }
            killed = true
            process.terminate()
            return true
        }

        /// Last resort after a graceful terminate was ignored.
        @discardableResult
        func killIfRunning() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let process, process.isRunning else { return false }
            kill(process.processIdentifier, SIGKILL)
            return true
        }

        var wasKilled: Bool {
            lock.lock(); defer { lock.unlock() }
            return killed
        }
    }

    /// Runs `command` and reports the bounded outcome plus stderr excerpt on
    /// the main actor. Always calls back exactly once, including for launch
    /// failures; a hung child is killed at the timeout.
    static func run(command: String, environment: [String: String],
                    completion: @escaping @MainActor @Sendable (JoinHookRun.Outcome, String?) -> Void) {
        let execution = Execution()
        let process = Process()
        // The user's login shell resolves their PATH (GUI apps see none of
        // Homebrew etc.) and honors their dotfiles; zsh is the fallback.
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/bin/zsh")
        process.executableURL = shell
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            execution.appendStderr(chunk)
            if execution.stderrOverflowing { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { terminated in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Buffered stderr is still readable after child exit.
            if let rest = try? stderrPipe.fileHandleForReading.readToEnd() { execution.appendStderr(rest) }
            try? stderrPipe.fileHandleForReading.close()
            guard execution.finish() else { return }
            let outcome = Self.outcome(for: terminated, execution: execution)
            let excerpt = JoinHook.excerpt(from: execution.stderr)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(outcome, excerpt)
                }
            }
        }
        execution.install(process)
        queue.asyncAfter(deadline: .now() + JoinHook.timeoutSeconds) {
            if execution.terminateIfRunning() {
                Self.queue.asyncAfter(deadline: .now() + 2) { execution.killIfRunning() }
            }
        }
        do {
            try process.run()
        } catch {
            // No termination handler will fire for a process that never ran.
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            guard execution.finish() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(.launchFailure(error.localizedDescription), nil)
                }
            }
        }
    }

    private static func outcome(for process: Process, execution: Execution) -> JoinHookRun.Outcome {
        // The watchdog's SIGTERM (or SIGKILL) is the timeout; a signal we did
        // not send is an ordinary failure with the negative signal number.
        if execution.wasKilled, process.terminationReason == .uncaughtSignal { return .timeout }
        if process.terminationReason == .uncaughtSignal { return .failure(exitCode: -Int(process.terminationStatus)) }
        return process.terminationStatus == 0 ? .success : .failure(exitCode: Int(process.terminationStatus))
    }
}
