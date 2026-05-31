import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import WindowlessReaperCore

// M5: real AX/NSWorkspace/NSRunningApplication implementations.
//
// These implementations are excluded from the coverage gate (per
// docs/IMPLEMENTATION_PLAN.md §12). The contract verified here is narrow:
//
//   - The types are constructable from any actor context.
//   - They are `Sendable` and conform to the protocols.
//   - They return without crashing when called on the test runner. (The runner
//     has no Accessibility grant, so AX queries return `.unknown`; that's the
//     documented graceful-degradation behaviour and is what we assert.)
//   - `wreaper status` produces deterministically-ordered output with the
//     expected per-app line shape, so the manual golden snapshot from the M5
//     plan can be recorded on a real machine without further code changes.

extension Tag {
    @Tag static var integration: Self
}

private enum IntegrationHost {
    private static let runFlag = "WREAPER_RUN_INTEGRATION_TESTS"
    private static let onConsoleKey = kCGSessionOnConsoleKey as String

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[runFlag] == "1" && isGUIConsoleSession
    }

    static var isGUIConsoleSession: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session[onConsoleKey] as? Bool) == true
    }

    static var isAXTrusted: Bool {
        AXIsProcessTrusted()
    }
}

@Suite(
    "M5 — integration: real AX wrappers",
    .tags(.integration),
    .disabled(if: !IntegrationHost.isEnabled, "Set WREAPER_RUN_INTEGRATION_TESTS=1 from a GUI console session"),
    .timeLimit(.minutes(1))
)
struct M5RealAXTests {
    @Test("NSWorkspaceAppEnumerator returns currently-running regular apps")
    func enumeratorReturnsApps() async {
        let enumerator = NSWorkspaceAppEnumerator()
        let apps = await enumerator.enumerate()

        // At least one .regular app must be running on any macOS host running
        // the test suite (Finder, the test runner host process, …). We don't
        // assert which apps — just that the enumeration produced something
        // shaped correctly and survived nil-bundle-ID filtering.
        #expect(!apps.isEmpty)
        for app in apps {
            #expect(!app.bundleID.value.isEmpty)
            #expect(app.pid > 0)
        }
    }

    @Test(
        "AXWindowInspector returns .unknown for a pid with no granted AX access",
        .disabled(if: IntegrationHost.isAXTrusted, "This smoke test covers the no-trust path")
    )
    func inspectorReturnsNoneWithoutAccess() async {
        // The test runner is not in System Settings → Accessibility. AX calls
        // for arbitrary PIDs fail with kAXErrorAPIDisabled or
        // kAXErrorNotAuthorized; the inspector normalises that to `.unknown`
        // so the engine does not treat permission-denied as a real windowless
        // state.
        //
        // Using our own PID guarantees the call path exercises a real running
        // process, not a defunct one — without depending on which other apps
        // happen to be running.
        let inspector = AXWindowInspector()
        let state = await inspector.windowState(for: ProcessInfo.processInfo.processIdentifier)
        #expect(state == .unknown)
    }

    @Test("NSRunningApplicationTerminator returns false for a non-existent pid")
    func terminatorReturnsFalseForMissingPID() async {
        // pid 0 is never a real user process; NSRunningApplication(processIdentifier:)
        // returns nil and we surface that as `false` rather than crashing.
        let terminator = NSRunningApplicationTerminator()
        let ok = await terminator.terminate(pid: 0)
        #expect(!ok)
    }

    @Test("`wreaper status` prints a stable line per running app, sorted by bundle ID")
    func statusCommandProducesSortedOutput() async throws {
        let binary = TestProcessRunner.product(named: "wreaper")
        let output = try await TestProcessRunner.runExpectingSuccess(binary: binary, arguments: ["status"])

        let lines = output.combinedOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        #expect(!lines.isEmpty, "wreaper status produced no output")

        // Every line: "<bundle.id>\tpid=<n>\tstate=<none|minimised|visible|unknown>"
        let states = Set(["none", "minimised", "visible", "unknown"])
        var bundleIDs: [String] = []
        for line in lines {
            let parts = line.split(separator: "\t").map(String.init)
            try #require(parts.count == 3, "bad line shape: \(line)")
            let bid = parts[0]
            #expect(!bid.isEmpty)
            #expect(parts[1].hasPrefix("pid="))
            #expect(parts[2].hasPrefix("state="))
            let state = String(parts[2].dropFirst("state=".count))
            #expect(states.contains(state), "unexpected state: \(state)")
            bundleIDs.append(bid)
        }

        // Sorted (ignoring per-pid ordering within a bundle) — this is what
        // makes the golden snapshot stable across runs.
        let bundleOrder = bundleIDs
        let sortedOrder = bundleIDs.sorted()
        #expect(bundleOrder == sortedOrder, "output not sorted by bundle ID")
    }
}
