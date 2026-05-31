import Foundation
import Testing
import WindowlessReaperCore

/// `screensDidSleep` / `didWakeNotification` are not posted for every flavor
/// of macOS suspension — particularly dark wake on AC, where the CPU resumes
/// for background maintenance without any AppKit broadcast. Without these
/// notifications, the existing power-state gate and wake-grace flag stay
/// inert and the engine ticks on a stale elapsed-time view, mass-evicting
/// apps the user thought were safely backgrounded.
///
/// These tests pin the fallback path: comparing `ContinuousClock` (which
/// advances during system sleep) against `SuspendingClock` (which does not)
/// lets the engine notice an implicit suspension and skip one tick — same
/// behaviour as an explicit wake grace.
@Suite("Implicit wake detection via clock drift", .timeLimit(.minutes(1)))
struct ImplicitWakeDetectionTests {
    private func makeEngine(
        enumerator: FakeAppEnumerator = FakeAppEnumerator(),
        clock: TestClock,
        powerState: FakePowerState = FakePowerState(initiallyVisible: true),
        sleepWake: FakeSleepWake = FakeSleepWake()
    ) -> ReaperEngine {
        ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [:]),
            enumerator: enumerator,
            inspector: FakeWindowInspector(),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: sleepWake,
            powerState: powerState
        )
    }

    @Test("large continuous-only drift skips one tick")
    func largeDriftSkipsTick() async {
        let enumerator = FakeAppEnumerator(apps: [])
        let clock = TestClock()
        let engine = makeEngine(enumerator: enumerator, clock: clock)

        // First tick establishes baseline timestamps.
        _ = await engine.tick()
        let baseline = await enumerator.callCount
        #expect(baseline == 1, "baseline tick must enumerate")

        // Simulate the system sleeping for an hour: continuous advances, suspending does not.
        await clock.advanceContinuousOnly(by: Duration(seconds: 3600))

        let decisions = await engine.tick()
        #expect(decisions.isEmpty, "implicit-wake tick must short-circuit")
        let afterDrift = await enumerator.callCount
        #expect(afterDrift == baseline, "implicit-wake tick must not enumerate")
    }

    @Test("small drift (within threshold) does not skip")
    func smallDriftProceeds() async {
        let enumerator = FakeAppEnumerator(apps: [])
        let clock = TestClock()
        let engine = makeEngine(enumerator: enumerator, clock: clock)

        _ = await engine.tick()
        let baseline = await enumerator.callCount

        // 2s drift — well under the 5s threshold; ordinary scheduling jitter.
        await clock.advance(by: Duration(seconds: 30))
        await clock.advanceContinuousOnly(by: Duration(seconds: 2))

        _ = await engine.tick()
        let after = await enumerator.callCount
        #expect(after == baseline + 1, "sub-threshold drift must not suppress the tick")
    }

    @Test("first-ever tick has no baseline and runs normally")
    func firstTickRuns() async {
        let enumerator = FakeAppEnumerator(apps: [])
        let clock = TestClock()
        let engine = makeEngine(enumerator: enumerator, clock: clock)

        // Even if continuous is far ahead at boot, the engine has nothing to
        // compare against and must not refuse its very first tick.
        await clock.advanceContinuousOnly(by: Duration(seconds: 86400))

        _ = await engine.tick()
        #expect(await enumerator.callCount == 1, "first tick must run regardless of clock skew")
    }

    @Test("after implicit-wake skip, next tick proceeds normally")
    func recoveryTick() async {
        let enumerator = FakeAppEnumerator(apps: [])
        let clock = TestClock()
        let engine = makeEngine(enumerator: enumerator, clock: clock)

        _ = await engine.tick() // baseline
        await clock.advanceContinuousOnly(by: Duration(seconds: 3600)) // implicit sleep
        _ = await engine.tick() // skipped
        let afterSkip = await enumerator.callCount

        // Next interval with normal advancement on both clocks — must run.
        await clock.advance(by: Duration(seconds: 30))
        _ = await engine.tick()
        #expect(await enumerator.callCount == afterSkip + 1, "tick after the implicit-wake skip must run")
    }

    @Test("drift caught after power-state transition resets the tick loop")
    func driftAfterPowerStateTransition() async {
        let clock = TestClock()
        let powerState = FakePowerState(initiallyVisible: true)
        let sleepWake = FakeSleepWake()
        let enumerator = FakeAppEnumerator(apps: [])
        let engine = makeEngine(
            enumerator: enumerator,
            clock: clock,
            powerState: powerState,
            sleepWake: sleepWake
        )

        // Establish baseline.
        _ = await engine.tick()
        #expect(await enumerator.callCount == 1)

        // Simulate display sleep: epoch ends, no more ticks fire.
        powerState.setVisible(false)
        _ = await engine.tick()
        #expect(await enumerator.callCount == 1, "invisible tick must not enumerate")

        // Simulate 1 hour of sleep while invisible — continuous advances.
        await clock.advanceContinuousOnly(by: Duration(seconds: 3600))

        // Simulate wake + visibility restored.
        powerState.setVisible(true)
        // FakeSleepWake does NOT arm its grace flag here — this tests the
        // drift-detector fallback when both NSWorkspace and IOKit miss the
        // wake notification.

        // First tick after visible — drift > 5s, must be skipped.
        let decisions = await engine.tick()
        #expect(decisions.isEmpty, "post-sleep tick must be skipped even when sleepWake is silent")
        #expect(await enumerator.callCount == 1, "skipped tick must not enumerate")
    }

    @Test("implicit wake takes precedence over normal eviction work")
    func implicitWakePreemptsEviction() async {
        // App is windowless from t=0; without the drift check, the post-sleep
        // tick would see elapsed >> timeout and evict immediately.
        let safari = BundleID("com.apple.Safari")
        let rule = Rule(timeout: Duration(seconds: 60))
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 42)])
        let inspector = FakeWindowInspector(default: .none)
        let terminator = FakeTerminator()
        let clock = TestClock()
        let engine = ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [safari: rule]),
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(initiallyVisible: true)
        )

        _ = await engine.tick() // start tracking
        await clock.advanceContinuousOnly(by: Duration(seconds: 7200)) // 2h "sleep"

        _ = await engine.tick()
        #expect(await terminator.terminatedPIDs.isEmpty, "must not terminate on the implicit-wake tick")
    }
}
