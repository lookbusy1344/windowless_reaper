import Foundation
import Testing
import WindowlessReaperCore

private struct LaunchctlCall: Equatable {
    let executablePath: String
    let arguments: [String]
    let timeout: Swift.Duration
}

private actor LaunchctlFakeRunner: ProcessRunner {
    private(set) var calls: [LaunchctlCall] = []
    private var nextResult = ProcessExecutionResult(terminationStatus: 0, standardOutput: "", standardError: "")

    func setNextResult(_ result: ProcessExecutionResult) {
        nextResult = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: Swift.Duration
    ) async throws -> ProcessExecutionResult {
        calls.append(
            LaunchctlCall(
                executablePath: executableURL.path,
                arguments: arguments,
                timeout: timeout
            )
        )
        return nextResult
    }

    func snapshot() -> [LaunchctlCall] {
        calls
    }
}

private enum RunnerTestError: Error, Equatable {
    case simulatedTimeout
}

private actor LaunchctlTimeoutRunner: ProcessRunner {
    func run(
        executableURL _: URL,
        arguments _: [String],
        timeout _: Swift.Duration
    ) async throws -> ProcessExecutionResult {
        throw RunnerTestError.simulatedTimeout
    }
}

private actor LaunchctlCancelAwareRunner: ProcessRunner {
    private(set) var observedCancellation = false

    func run(
        executableURL _: URL,
        arguments _: [String],
        timeout _: Swift.Duration
    ) async throws -> ProcessExecutionResult {
        do {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }

    func cancellationObserved() -> Bool {
        observedCancellation
    }
}

@Suite("Launchctl client", .timeLimit(.minutes(1)))
struct LaunchctlClientTests {
    @Test("system client sends bootstrap and bootout through an injected runner")
    func usesInjectedRunner() async throws {
        let runner = LaunchctlFakeRunner()
        let client = SystemLaunchctlClient(runner: runner)

        try await client.bootstrap(plistPath: "/tmp/a.plist", uid: 501)
        try await client.bootout(plistPath: "/tmp/a.plist", uid: 501)

        let calls = await runner.snapshot()
        #expect(calls.count == 2)
        #expect(calls[0].executablePath == "/bin/launchctl")
        #expect(calls[0].arguments == ["bootstrap", "gui/501", "/tmp/a.plist"])
        #expect(calls[1].arguments == ["bootout", "gui/501", "/tmp/a.plist"])
        #expect(calls[0].timeout == SystemLaunchctlClient.launchctlTimeout)
        #expect(calls[1].timeout == SystemLaunchctlClient.launchctlTimeout)
    }

    @Test("non-zero exit maps to LaunchctlError.nonZeroExit")
    func nonZeroExitBecomesTypedError() async {
        let runner = LaunchctlFakeRunner()
        await runner.setNextResult(
            ProcessExecutionResult(
                terminationStatus: 113,
                standardOutput: "",
                standardError: "Could not find specified service"
            )
        )
        let client = SystemLaunchctlClient(runner: runner)

        await #expect(throws: LaunchctlError.self) {
            try await client.bootout(plistPath: "/tmp/a.plist", uid: 501)
        }
    }

    @Test("runner timeout error propagates as a typed error")
    func runnerTimeoutPropagates() async {
        let runner = LaunchctlTimeoutRunner()
        let client = SystemLaunchctlClient(runner: runner)

        await #expect(throws: RunnerTestError.simulatedTimeout) {
            try await client.bootstrap(plistPath: "/tmp/a.plist", uid: 501)
        }
    }

    @Test("cancellation propagates to a stalled runner")
    func cancellationPropagates() async throws {
        let runner = LaunchctlCancelAwareRunner()
        let client = SystemLaunchctlClient(runner: runner)

        let task = Task {
            try await client.bootstrap(plistPath: "/tmp/a.plist", uid: 501)
        }
        await Task.yield()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await runner.cancellationObserved())
    }
}
