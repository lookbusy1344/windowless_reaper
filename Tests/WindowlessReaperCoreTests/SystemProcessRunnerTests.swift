import Foundation
import Testing
import WindowlessReaperCore

@Suite("SystemProcessRunner timeout", .timeLimit(.minutes(1)))
struct SystemProcessRunnerTests {
    /// The runner must raise a typed timeout error (not silently abandon
    /// the child) when a never-exiting process exceeds the deadline.
    /// The child ignores SIGTERM so the 500 ms grace window expires and
    /// SIGKILL terminates it.
    @Test("timeout raises ProcessRunnerError for a never-exiting child")
    func timeoutRaisesTypedError() async throws {
        let runner = SystemProcessRunner()

        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while true; do :; done"],
                timeout: .milliseconds(100)
            )
            Issue.record("expected timedOut error but runner returned successfully")
        } catch is ProcessRunnerError {
            // Success — the runner surfaced the typed timeout instead of
            // silently abandoning the child.
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// When the child honours SIGTERM and exits within the grace window,
    /// the runner must still surface ProcessRunnerError.timedOut — it must
    /// not let the termination handler resume with a normal result.
    @Test("timeout raises ProcessRunnerError for a SIGTERM-honoring child")
    func timeoutRaisesTypedErrorForSigtermHonoringChild() async throws {
        let runner = SystemProcessRunner()

        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while true; do sleep 1; done"],
                timeout: .milliseconds(100)
            )
            Issue.record("expected timedOut error but runner returned successfully")
        } catch is ProcessRunnerError {
            // Success — the runner surfaced the typed timeout in preference
            // to a normal result from the termination handler.
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
