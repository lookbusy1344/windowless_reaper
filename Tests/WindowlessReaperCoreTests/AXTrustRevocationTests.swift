import Foundation
import Synchronization
import Testing
import WindowlessReaperCore

/// Tests for §4.15: when Accessibility trust is silently revoked during
/// sleep (the typical trigger is a Homebrew upgrade replacing the signed
/// binary), the next wake's AX re-check flips the engine into a paused
/// state. Eviction decisions continue to be produced and logged — so
/// diagnostics remain accurate — but the terminator is never called.
@Suite("AX trust revocation", .timeLimit(.minutes(1)))
struct AXTrustRevocationTests {
    @Test("evictions stop after revocation and resume when trust is restored")
    func revocationAndRestoration() async {
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
        let terminator = FakeTerminator()
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)]),
            inspector: FakeWindowInspector(states: [11: .none]),
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        // Step 1: revoke trust. Next eviction tick must produce a decision
        // but not call the terminator.
        await engine.updateAccessibilityRevoked(true)
        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        let revokedDecisions = await engine.tick()
        #expect(
            revokedDecisions.contains { if case .evict = $0 { true } else { false } },
            "revoked engine must still produce evict decisions for observability"
        )
        let killedWhileRevoked = await terminator.terminatedPIDs
        #expect(killedWhileRevoked.isEmpty, "AX-revoked engine must not call terminate()")

        // Step 2: restore trust. The next eviction tick must terminate.
        await engine.updateAccessibilityRevoked(false)
        await clock.advance(by: Duration(seconds: 1))
        _ = await engine.tick()
        let killedAfterRestore = await terminator.terminatedPIDs
        #expect(killedAfterRestore.contains(11), "restored trust must re-enable evictions")
    }

    @Test("redundant flag updates are no-ops")
    func redundantUpdatesNoOp() async {
        let engine = ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [:]),
            enumerator: FakeAppEnumerator(apps: []),
            inspector: FakeWindowInspector(states: [:]),
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        #expect(await engine.isAccessibilityRevoked() == false)
        await engine.updateAccessibilityRevoked(true)
        await engine.updateAccessibilityRevoked(true)
        #expect(await engine.isAccessibilityRevoked() == true)
        await engine.updateAccessibilityRevoked(false)
        #expect(await engine.isAccessibilityRevoked() == false)
    }
}
