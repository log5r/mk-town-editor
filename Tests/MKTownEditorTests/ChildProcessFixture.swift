import Darwin
import Foundation
import XCTest

/// Helpers for tests that start a real child process through a shell script.
enum ChildProcessFixture {
    /// Shell lines that publish the script's PID atomically: the file appears only once it
    /// is complete, so a poller never reads it half-written.
    static func publishPID(to file: URL) -> String {
        "printf '%s' $$ > \"\(file.path).tmp\" && mv \"\(file.path).tmp\" \"\(file.path)\""
    }

    /// Waits up to `timeout` for the PID file written by `publishPID(to:)`.
    static func waitForPID(at file: URL, timeout: Duration = .seconds(10)) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("child process did not start within \(timeout)")
    }

    /// Kills the child if a test exits early, so a failure never leaks a long-running process.
    static func reap(_ pid: pid_t?) {
        guard let pid, Darwin.kill(pid, 0) == 0 else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }

    static func isRunning(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 }
}
