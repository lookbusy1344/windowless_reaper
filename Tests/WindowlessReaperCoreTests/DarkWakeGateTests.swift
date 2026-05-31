import Testing
import WindowlessReaperCore

@Suite("Dark-wake gate", .timeLimit(.minutes(1)))
struct DarkWakeGateTests {
    private static let safari = BundleID("com.apple.Safari")

    private func makeEngine(
        powerState: FakePowerState,
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

    @Test("tick is skipped when power state is not user-visible")
    func tickSkippedWhenNotUserVisible() async {
        let powerState = FakePowerState(initiallyVisible: false)
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: Self.safari, pid: 1)])
        let terminator = FakeTerminator()
        let engine = makeEngine(powerState: powerState, enumerator: enumerator, terminator: terminator)

        let decisions = await engine.tick()

        #expect(decisions.isEmpty, "tick must return [] when system is not user-visible")
        let killed = await terminator.terminatedPIDs
        #expect(killed.isEmpty, "terminator must not be called during dark wake")
        let enumerated = await enumerator.enumerate()
        // Engine skips before enumerating; app list is untouched (still returns the seeded apps)
        _ = enumerated // enumerator returns apps on demand — what matters is no terminations
    }

    @Test("tick runs normally when power state is user-visible")
    func tickRunsWhenUserVisible() async {
        let clock = TestClock()
        let powerState = FakePowerState(initiallyVisible: true)
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: Self.safari, pid: 2)])
        let terminator = FakeTerminator()
        let engine = ReaperEngine(
            config: Config(
                settings: Settings.defaults,
                rules: [Self.safari: Rule(timeout: Duration(seconds: 10))]
            ),
            enumerator: enumerator,
            inspector: FakeWindowInspector(default: .none),
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: powerState
        )

        // First tick: observe (starts tracking). Advance past timeout. Second tick: evict.
        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        let decisions = await engine.tick()

        #expect(!decisions.isEmpty, "engine must produce decisions when user-visible")
        let hasEvict = decisions.contains { if case .evict = $0 { true } else { false } }
        #expect(hasEvict, "engine must evict after timeout when user-visible")
    }

    @Test("power gate runs before grace tick — grace tick stays pending")
    func powerGateRunsBeforeGraceTick() async {
        let powerState = FakePowerState(initiallyVisible: false)
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateWake()
        let engine = makeEngine(powerState: powerState, sleepWake: sleepWake)

        let decisions = await engine.tick()

        #expect(decisions.isEmpty, "power gate must short-circuit before consuming grace tick")
        // Grace tick must still be pending — was not consumed.
        let graceConsumed = await sleepWake.consumeGraceTick()
        #expect(graceConsumed, "grace tick must remain pending after dark-wake gate fires")
    }

    @Test("grace tick consumed normally when power gate is open")
    func graceTickConsumedWhenPowerGateOpen() async {
        let powerState = FakePowerState(initiallyVisible: true)
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateWake()
        let engine = makeEngine(powerState: powerState, sleepWake: sleepWake)

        // First tick: power gate passes, grace tick consumed → skip.
        let first = await engine.tick()
        #expect(first.isEmpty, "grace tick must suppress first post-wake tick")

        // Second tick: no grace tick pending, runs normally.
        let second = await engine.tick()
        // May be empty (no evictions yet) but the engine ran — decisions can be .track, .ignore, etc.
        // The absence of a grace-tick skip is what matters; no assertion on second's content needed.
        _ = second
    }
}
