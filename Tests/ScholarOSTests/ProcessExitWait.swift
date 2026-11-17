import Darwin
import Foundation

/// Thrown where a test cannot use `#expect` (for example inside `Task.detached`) and a child
/// process did not exit in time.
struct ProcessDidNotExit: Error, CustomStringConvertible {
    let description: String
}

extension Process {
    /// Waits for the child to exit by polling `isRunning`. Tests use this instead of
    /// `waitUntilExit()`.
    ///
    /// `waitUntilExit()` sleeps in the calling thread's run loop until something wakes it. Called
    /// from an async test, on a Swift concurrency thread, that wake-up can be missed: on 2026-11-18
    /// AgentVM's `Scripts/test.sh milestone 0` sat in `waitUntilExit()` for hours although the
    /// child had already exited and been reaped. Foundation updates `isRunning` and
    /// `terminationStatus` without a run loop, so polling them does not depend on that wake-up.
    ///
    /// If the child is still running after `timeoutSeconds`, it is killed with `SIGKILL` (so
    /// `terminationStatus` can still be read) and the result is `false`.
    @discardableResult
    func waitForExit(timeoutSeconds: TimeInterval = 60) -> Bool {
        if pollUntilExited(deadline: Date().addingTimeInterval(timeoutSeconds)) {
            return true
        }
        _ = Darwin.kill(processIdentifier, SIGKILL)
        _ = pollUntilExited(deadline: Date().addingTimeInterval(5))
        return false
    }

    private func pollUntilExited(deadline: Date) -> Bool {
        while isRunning {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}
