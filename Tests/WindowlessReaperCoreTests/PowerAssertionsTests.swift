import Darwin
import Foundation
import Testing
import WindowlessReaperCore

/// Regression test for power_man_best_practices.md §4.6: the supervisor loop
/// must not hold any sleep-prevention `IOPMAssertion`. The whole product
/// hypothesis is that the laptop sleeps and our timers pause with it; an
/// accidental `.idleSystemSleepDisabled` or hand-rolled
/// `IOPMAssertionCreateWithName` would silently defeat that.
///
/// Reads `pmset -g assertions` (a process-listing of every active assertion
/// and its owning PID) and asserts no entry for our own PID names a
/// sleep-prevention type. Skips cleanly when `pmset` is unavailable (CI
/// sandboxes) rather than reporting a false failure.
@Suite("Power assertions", .timeLimit(.minutes(1)))
struct PowerAssertionsTests {
    @Test("runLoopHoldsNoSleepPreventingAssertion: beginActivity(.background) does not register as PreventSystemSleep")
    func runLoopHoldsNoSleepPreventingAssertion() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: []),
            inspector: FakeWindowInspector(states: [:]),
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        let task = Task { await engine.run() }
        defer { task.cancel() }

        // Give the run loop time to call beginActivity. The first tick fires
        // immediately on the test clock, so by the time the first scan is
        // observable runningboardd has seen our activity hint.
        try await Task.sleep(for: .milliseconds(200))

        guard let assertions = try await runPmsetAssertions() else {
            // pmset unavailable (sandbox / CI) — assertion absence cannot be
            // verified from inside the process. Skip rather than false-fail.
            return
        }

        let pid = getpid()
        let ownerHeader = "pid \(pid)"
        let sleepPreventingTypes = [
            "PreventUserIdleSystemSleep",
            "PreventSystemSleep",
            "NoIdleSleepAssertion",
        ]

        // pmset groups assertions by owning process under a "pid N(name):"
        // header. Walk to our header and scan its block for forbidden types.
        var inOurBlock = false
        for line in assertions.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid ") {
                inOurBlock = trimmed.hasPrefix(ownerHeader)
                continue
            }
            guard inOurBlock else { continue }
            for type in sleepPreventingTypes {
                #expect(
                    !line.contains(type),
                    "wreaper test process pid \(pid) holds forbidden assertion \(type): \(line)"
                )
            }
        }
    }

    private func runPmsetAssertions() async throws -> String? {
        let result: ProcessExecutionResult
        do {
            result = try await TestProcessRunner.run(
                binary: URL(fileURLWithPath: "/usr/bin/pmset"),
                arguments: ["-g", "assertions"]
            )
        } catch {
            return nil
        }
        guard result.terminationStatus == 0 else { return nil }
        return result.standardOutput
    }
}
