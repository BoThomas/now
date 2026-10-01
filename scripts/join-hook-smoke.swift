import Foundation
import NowCore

extension NotificationSmoke {
    /// Exercise production process supervision without real meetings or notifications.
    @MainActor static func joinHookRunnerTests() async {
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("FAIL join hook runner: " + message); exit(1) }
        }
        let overflowStart = Date()
        let overflow = await hookResult(command: "/usr/bin/head -c 1048576 /dev/zero >&2; :")
        require(overflow.0 == .success, "large stderr drains without blocking the command")
        require(Date().timeIntervalSince(overflowStart) < JoinHook.timeoutSeconds, "stderr overflow completes before watchdog")
        require(overflow.1?.count == 200, "large stderr retains only the bounded excerpt")

        let title = "Team \"Sync\"; $(printf injected)\nnext line"
        let failure = await hookResult(command: "printf '%s' \"$NOW_TITLE\" >&2; /bin/sleep 0.1; exit 3",
                                       environment: ["NOW_TITLE": title])
        require(failure.0 == .failure(exitCode: 3) && failure.1 == title, "environment content remains literal and exit code is recorded")

        let detachedStart = Date()
        let detached = await hookResult(command: "/bin/sleep 3 & :")
        require(detached.0 == .success && Date().timeIntervalSince(detachedStart) < 2,
                "a child's inherited stderr does not delay shell completion")
        let failedLaunch = await hookResult(command: ":", shell: URL(fileURLWithPath: "/nonexistent/now-join-hook-test-shell"))
        if case .launchFailure = failedLaunch.0 {} else { require(false, "missing shell reports launch failure") }

        // Real production deadlines, run concurrently to keep the smoke bounded.
        async let cleanTrap = hookResult(command: "trap 'exit 0' TERM; while :; do /bin/sleep 0.1; done")
        async let errorTrap = hookResult(command: "trap 'exit 7' TERM; while :; do /bin/sleep 0.1; done")
        async let ignored = hookResult(command: "trap '' TERM; while :; do /bin/sleep 0.1; done")
        let timeouts = await (cleanTrap, errorTrap, ignored)
        require(timeouts.0.0 == .timeout && timeouts.1.0 == .timeout, "handled SIGTERM stays a timeout for zero and nonzero exits")
        require(timeouts.2.0 == .timeout, "ignored SIGTERM reaches SIGKILL and completes")
        print("JOIN HOOK RUNNER OK — stderr drain/cap, literal environment, detached child, launch failure, timeout traps and kill")
    }

    @MainActor private static func hookResult(command: String, environment: [String: String] = [:],
                                              shell: URL = URL(fileURLWithPath: "/bin/zsh")) async -> (JoinHookRun.Outcome, String?) {
        await withCheckedContinuation { continuation in
            JoinHookRunner.smokeRun(command: command, environment: environment, shell: shell) { outcome, excerpt in
                continuation.resume(returning: (outcome, excerpt))
            }
        }
    }
}
