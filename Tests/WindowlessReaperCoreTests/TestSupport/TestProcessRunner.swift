import Foundation
import WindowlessReaperCore

enum TestProcessRunner {
    static let defaultTimeout: Swift.Duration = .seconds(10)

    static func product(named name: String) -> URL {
        productsDirectory.appendingPathComponent(name)
    }

    static func run(
        binary: URL,
        arguments: [String],
        timeout: Swift.Duration = defaultTimeout
    ) async throws -> ProcessExecutionResult {
        let processBox = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ProcessExecutionResult.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        let process = Process()
                        process.executableURL = binary
                        process.arguments = arguments
                        let standardOutput = Pipe()
                        let standardError = Pipe()
                        process.standardOutput = standardOutput
                        process.standardError = standardError
                        processBox.process = process

                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try process.run()
                                process.waitUntilExit()
                                let stdoutData = standardOutput.fileHandleForReading.readDataToEndOfFile()
                                let stderrData = standardError.fileHandleForReading.readDataToEndOfFile()
                                continuation.resume(
                                    returning: ProcessExecutionResult(
                                        terminationStatus: process.terminationStatus,
                                        standardOutput: String(bytes: stdoutData, encoding: .utf8) ?? "",
                                        standardError: String(bytes: stderrData, encoding: .utf8) ?? ""
                                    )
                                )
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TestProcessRunnerError.timedOut(
                        command: ([binary.path] + arguments).joined(separator: " "),
                        timeout: timeout
                    )
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
        } onCancel: {
            processBox.process?.terminate()
        }
    }

    static func runExpectingSuccess(
        binary: URL,
        arguments: [String],
        timeout: Swift.Duration = defaultTimeout
    ) async throws -> ProcessExecutionResult {
        let result = try await run(binary: binary, arguments: arguments, timeout: timeout)
        guard result.terminationStatus == 0 else {
            throw TestProcessRunnerError.nonZeroExit(
                command: ([binary.path] + arguments).joined(separator: " "),
                status: result.terminationStatus,
                stdout: result.standardOutput,
                stderr: result.standardError
            )
        }
        return result
    }

    private static var productsDirectory: URL {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--test-bundle-path"), idx + 1 < args.count {
            return stripBundleWrappers(URL(fileURLWithPath: args[idx + 1]).deletingLastPathComponent())
        }
        return stripBundleWrappers(Bundle.main.bundleURL)
    }

    private static func stripBundleWrappers(_ start: URL) -> URL {
        var url = start
        while url.pathExtension == "xctest" || url.lastPathComponent == "MacOS" || url.lastPathComponent == "Contents" {
            url = url.deletingLastPathComponent()
        }
        return url
    }
}

private final class ProcessBox: @unchecked Sendable {
    var process: Process?
}

enum TestProcessRunnerError: Error, Equatable {
    case nonZeroExit(command: String, status: Int32, stdout: String, stderr: String)
    case timedOut(command: String, timeout: Swift.Duration)
}
