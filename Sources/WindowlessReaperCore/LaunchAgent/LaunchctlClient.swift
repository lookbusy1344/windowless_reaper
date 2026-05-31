import Foundation
import os

/// Result from a spawned process. Captures stdout/stderr separately so tests
/// can assert on either stream without depending on the system runner.
public struct ProcessExecutionResult: Sendable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(terminationStatus: Int32, standardOutput: String, standardError: String) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var combinedOutput: String {
        standardOutput + standardError
    }
}

/// Seam for process execution. Production uses a system runner; tests inject a
/// fake runner that can simulate success, exit codes, output, and cancellation.
public protocol ProcessRunner: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: Swift.Duration
    ) async throws -> ProcessExecutionResult
}

/// Typed error for runner-level failures.
public enum ProcessRunnerError: Error, Equatable {
    case timedOut(command: String, timeout: Swift.Duration)
}

/// Seam for `launchctl bootstrap`/`bootout`. Real implementation shells out;
/// tests inject a fake that records the calls without touching launchd.
public protocol LaunchctlClient: Sendable {
    func bootstrap(plistPath: String, uid: uid_t) async throws
    func bootout(plistPath: String, uid: uid_t) async throws
}

public enum LaunchctlError: Error, Equatable {
    case nonZeroExit(command: String, status: Int32, output: String)

    /// `launchctl bootout` returns non-zero with status 113 ("Could not find
    /// specified service") when the service is already not loaded. Surface
    /// that distinction so `uninstall` can treat it as idempotent rather than
    /// as a failure.
    var isNotLoaded: Bool {
        switch self {
        case .nonZeroExit(_, let status, let output):
            status == 113 || output.lowercased().contains("could not find specified service")
        }
    }
}

/// Default system process runner. Uses `Process` with a termination handler so
/// callers do not block on `waitUntilExit()`.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public func run(
        executableURL: URL,
        arguments: [String],
        timeout: Swift.Duration
    ) async throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessExecutionResult, any Error>) in
                enum TimeoutPhase: Int { case running, timedOut, resumed }
                let phase = OSAllocatedUnfairLock<TimeoutPhase>(initialState: .running)

                // Resume from the `running` state (normal completion or spawn failure).
                // Returns false if another finisher (timeout watcher) already claimed
                // the continuation.
                let finishFromRunning: @Sendable (Result<ProcessExecutionResult, any Error>) -> Void = { result in
                    let shouldResume = phase.withLock { p -> Bool in
                        guard p == .running else { return false }
                        p = .resumed
                        return true
                    }
                    guard shouldResume else { return }
                    continuation.resume(with: result)
                }

                // Dedicated pipe buffer to avoid the readDataToEndOfFile deadlock:
                // if a child ever writes more than ~64 KiB to both pipes concurrently,
                // the child blocks before exit, the termination handler never fires,
                // and nobody is draining.  Consuming availableData as it arrives keeps
                // the pipe buffer clear during execution.
                let stdoutBuf = OSAllocatedUnfairLock<Data>(initialState: Data())
                let stderrBuf = OSAllocatedUnfairLock<Data>(initialState: Data())

                let timeoutTaskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

                process.terminationHandler = { terminated in
                    // Stop draining — the child has exited so no more data can arrive.
                    standardOutput.fileHandleForReading.readabilityHandler = nil
                    standardError.fileHandleForReading.readabilityHandler = nil

                    let stdoutData = stdoutBuf.withLock { buf in
                        buf.append(standardOutput.fileHandleForReading.availableData)
                        return buf
                    }
                    let stderrData = stderrBuf.withLock { buf in
                        buf.append(standardError.fileHandleForReading.availableData)
                        return buf
                    }

                    // Decide the outcome atomically with the phase transition so
                    // a child that exits during the SIGTERM grace window still
                    // surfaces as a timeout, and so the timeout watcher being
                    // cancelled below cannot leak the continuation.
                    let outcome: Result<ProcessExecutionResult, any Error>? = phase.withLock { p in
                        switch p {
                        case .running:
                            p = .resumed
                            return .success(ProcessExecutionResult(
                                terminationStatus: terminated.terminationStatus,
                                standardOutput: String(bytes: stdoutData, encoding: .utf8) ?? "",
                                standardError: String(bytes: stderrData, encoding: .utf8) ?? ""
                            ))
                        case .timedOut:
                            p = .resumed
                            return .failure(ProcessRunnerError.timedOut(
                                command: Self.commandDescription(executableURL: executableURL, arguments: arguments),
                                timeout: timeout
                            ))
                        case .resumed:
                            return nil
                        }
                    }
                    if let outcome { continuation.resume(with: outcome) }
                    timeoutTaskLock.withLock { $0 }?.cancel()
                }

                do {
                    try process.run()
                } catch {
                    finishFromRunning(.failure(error))
                    return
                }

                // Timeout watcher — owns the deadline and the process's life.
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }

                    // Mark as timed out before sending SIGTERM so the
                    // termination handler cannot resume with success.
                    let shouldTimeout = phase.withLock { p -> Bool in
                        guard p == .running else { return false }
                        p = .timedOut
                        return true
                    }
                    guard shouldTimeout else { return }

                    process.terminate()

                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }

                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }

                    // Claim the continuation from .timedOut; if the termination
                    // handler already ran (and resumed with a timeout error),
                    // phase is .resumed and this is a no-op.
                    let shouldResume = phase.withLock { p -> Bool in
                        guard p == .timedOut else { return false }
                        p = .resumed
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: ProcessRunnerError.timedOut(
                            command: Self.commandDescription(executableURL: executableURL, arguments: arguments),
                            timeout: timeout
                        ))
                    }
                }
                timeoutTaskLock.withLock { $0 = timeoutTask }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private static func commandDescription(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments).joined(separator: " ")
    }
}

/// Real implementation. Invokes `/bin/launchctl` through an injectable runner
/// and surfaces non-zero exits as typed errors so the install command can print
/// a useful message.
public struct SystemLaunchctlClient: LaunchctlClient {
    public static let launchctlTimeout: Swift.Duration = .seconds(10)

    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner = SystemProcessRunner()) {
        self.runner = runner
    }

    public func bootstrap(plistPath: String, uid: uid_t) async throws {
        try await run(["bootstrap", "gui/\(uid)", plistPath])
    }

    public func bootout(plistPath: String, uid: uid_t) async throws {
        try await run(["bootout", "gui/\(uid)", plistPath])
    }

    private func run(_ args: [String]) async throws {
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: args,
            timeout: Self.launchctlTimeout
        )
        if result.terminationStatus != 0 {
            throw LaunchctlError.nonZeroExit(
                command: "launchctl \(args.joined(separator: " "))",
                status: result.terminationStatus,
                output: result.combinedOutput
            )
        }
    }
}
