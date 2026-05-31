import Testing
import WindowlessReaperCore

/// Level-triggered sleep gate covers the dark-wake gap that the edge-triggered
/// `consumeGraceTick` and clock-drift detector cannot: a tick that fires
/// *during* a sleep interval (between `willSleep` and `willPowerOn`) when
/// `isUserVisible()` happens to return true. See docs/plans/sleep-state-gate.md
/// for the 2026-05-15 incident this regression-covers.
@Suite("Sleep-state gate", .timeLimit(.minutes(1)))
struct SleepGateTests {
    private static let safari = BundleID("com.apple.Safari")

    private func makeEngine(
        powerState: FakePowerState = FakePowerState(initiallyVisible: true),
        sleepWake: FakeSleepWake = FakeSleepWake(),
        enumerator: FakeAppEnumerator = FakeAppEnumerator(),
        terminator: FakeTerminator = FakeTerminator()
    ) -> ReaperEngine {
        ReaperEngine(
            config: Config(
                settings: Settings.defaults,
                rules: [Self.safari: Rule(timeout: Duration(seconds: 10))]
            ),
            enumerator: enumerator,
            inspector: FakeWindowInspector(default: .none),
            terminator: terminator,
            clock: TestClock(),
            sleepWake: sleepWake,
            powerState: powerState
        )
    }

    @Test("tick is skipped when sleepWake reports asleep")
    func tickSkippedWhenAsleep() async {
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateSleep()
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: Self.safari, pid: 1)])
        let terminator = FakeTerminator()
        let engine = makeEngine(sleepWake: sleepWake, enumerator: enumerator, terminator: terminator)

        let decisions = await engine.tick()

        #expect(decisions.isEmpty, "tick must return [] while asleep")
        let killed = await terminator.terminatedPIDs
        #expect(killed.isEmpty, "terminator must not be called while asleep")
    }

    @Test("tick runs after simulateWake clears the asleep flag")
    func tickRunsAfterWake() async {
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateSleep()
        let engine = makeEngine(sleepWake: sleepWake)

        // Asleep — skipped.
        let firstWhileAsleep = await engine.tick()
        #expect(firstWhileAsleep.isEmpty)

        // Wake clears asleep AND arms grace tick.
        await sleepWake.simulateWake()
        let firstAfterWake = await engine.tick()
        #expect(firstAfterWake.isEmpty, "post-wake grace tick must still suppress")

        // Subsequent tick: gates open.
        _ = await engine.tick()
        // No assertion on contents — what matters is the engine is no longer gated.
        #expect(await sleepWake.isAsleep() == false)
        #expect(await sleepWake.consumeGraceTick() == false, "grace tick already drained on prior tick")
    }

    @Test("sleep gate fires before power-visibility gate")
    func sleepGateBeforePowerGate() async {
        // Both gates would suppress the tick. The sleep gate must fire first;
        // we prove it by leaving the grace tick unconsumed (the existing
        // power-gate-first test shows that exact pattern: a gate firing first
        // means the later gates do not run).
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateSleep()
        await sleepWake.simulateWake() // wake leaves grace tick armed AND clears asleep
        await sleepWake.simulateSleep() // re-sleep without consuming grace tick — both pending

        let powerState = FakePowerState(initiallyVisible: false)
        let engine = makeEngine(powerState: powerState, sleepWake: sleepWake)

        let decisions = await engine.tick()
        #expect(decisions.isEmpty)

        // Sleep gate fired first → grace tick still pending.
        let graceConsumed = await sleepWake.consumeGraceTick()
        #expect(graceConsumed, "grace tick must remain pending after sleep gate fires")
    }

    @Test("sleep gate fires before grace tick — grace tick stays pending")
    func sleepGateBeforeGraceTick() async {
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateWake() // arms grace
        await sleepWake.simulateSleep() // also asleep
        let engine = makeEngine(sleepWake: sleepWake)

        let decisions = await engine.tick()
        #expect(decisions.isEmpty)

        let graceConsumed = await sleepWake.consumeGraceTick()
        #expect(graceConsumed, "grace tick must remain pending after sleep gate fires")
    }
}
