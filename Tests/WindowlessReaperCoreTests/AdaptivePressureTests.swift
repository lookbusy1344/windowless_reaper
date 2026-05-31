import Foundation
import Testing
import WindowlessReaperCore

/// Tests for the adaptive-pressure policy from power_man_best_practices.md
/// §4.12. The behaviour has three parts and each is exercised in isolation:
///
/// 1. `effectiveInterval` doubles on battery or in Low Power Mode and is a
///    no-op when `adaptive_pressure = false`.
/// 2. Under `thermalState >= .serious`, the engine still observes apps and
///    issues `.evict` decisions but the terminator is never called.
/// 3. Flipping `adaptive_pressure` off restores baseline eviction behaviour
///    even when thermal/battery are nominally pressuring.
@Suite("Adaptive pressure", .timeLimit(.minutes(1)))
struct AdaptivePressureTests {
    private func makeSettings(adaptive: Bool, interval: Int = 30) -> Settings {
        Settings(
            pollInterval: Duration(seconds: interval),
            logLevel: "info",
            dryRun: false,
            defaultCooldown: .multiplier(5.0),
            adaptivePressure: adaptive
        )
    }

    @Test("effectiveInterval: no-op when adaptive_pressure is false")
    func effectiveIntervalRespectsFlag() {
        let battery = PressureSnapshot(source: .battery, lowPowerMode: true, thermalState: .nominal)
        let base = Duration(seconds: 30)
        #expect(ReaperEngine.effectiveInterval(base, snapshot: battery, adaptive: false) == base)
    }

    @Test("effectiveInterval: doubles on battery")
    func effectiveIntervalDoublesOnBattery() {
        let battery = PressureSnapshot(source: .battery, lowPowerMode: false, thermalState: .nominal)
        let base = Duration(seconds: 30)
        let effective = ReaperEngine.effectiveInterval(base, snapshot: battery, adaptive: true)
        #expect(effective == Duration(seconds: 60))
    }

    @Test("effectiveInterval: doubles in Low Power Mode even on AC")
    func effectiveIntervalDoublesOnLPM() {
        let lpm = PressureSnapshot(source: .ac, lowPowerMode: true, thermalState: .nominal)
        let effective = ReaperEngine.effectiveInterval(Duration(seconds: 30), snapshot: lpm, adaptive: true)
        #expect(effective == Duration(seconds: 60))
    }

    @Test("effectiveInterval: unchanged on AC + no LPM regardless of thermal")
    func effectiveIntervalUnchangedOnAC() {
        let hot = PressureSnapshot(source: .ac, lowPowerMode: false, thermalState: .serious)
        let base = Duration(seconds: 30)
        #expect(ReaperEngine.effectiveInterval(base, snapshot: hot, adaptive: true) == base)
    }

    @Test("thermal >= serious pauses evictions when adaptive_pressure is true")
    func thermalPausesEvictions() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: makeSettings(adaptive: true),
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)])
        let inspector = FakeWindowInspector(states: [11: .none])
        let terminator = FakeTerminator()
        let clock = TestClock()
        let pressure = FakePowerPressure(
            PressureSnapshot(source: .ac, lowPowerMode: false, thermalState: .serious)
        )
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            pressure: pressure
        )

        // Two ticks across the 10s timeout: track at t=0, evict at t=20.
        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        let decisions = await engine.tick()

        // Decision is still produced — observability is preserved — but the
        // terminator is never called because of the thermal pause.
        #expect(decisions.contains { if case .evict = $0 { true } else { false } })
        let killed = await terminator.terminatedPIDs
        #expect(killed.isEmpty, "thermal pause must not call terminate()")
    }

    @Test("thermal pause is disabled when adaptive_pressure is false")
    func thermalPauseGatedByFlag() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: makeSettings(adaptive: false),
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        let terminator = FakeTerminator()
        let clock = TestClock()
        let pressure = FakePowerPressure(
            PressureSnapshot(source: .ac, lowPowerMode: false, thermalState: .critical)
        )
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)]),
            inspector: FakeWindowInspector(states: [11: .none]),
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            pressure: pressure
        )

        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        _ = await engine.tick()

        let killed = await terminator.terminatedPIDs
        #expect(
            killed.contains(11),
            "without adaptive_pressure thermal must not gate evictions — even at .critical"
        )
    }
}
