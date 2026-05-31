import Foundation
import Testing
import WindowlessReaperCore

/// Behavioural coverage for the willSleep-driven tick-stream teardown
/// added on 2026-05-15. Previously the engine relied only on the
/// `isAsleep()` check at tick start, which still let the
/// `DispatchSourceTimer` fire during dark-wake maintenance windows (one
/// no-op tick per dark-wake burst). After this change, willSleep
/// transitions tear the tick stream down entirely, and willPowerOn /
/// hasPoweredOn rebuild it.
///
/// The `isAsleep()` gate at tick start is retained as a belt-and-braces
/// backstop for the race where a tick is already in flight when the
/// sleep transition arrives — see `SleepGateTests` for that path.
@Suite("Sleep-state tick suspension", .timeLimit(.minutes(1)))
struct SleepStateTickSuspensionTests {
    private static let safari = BundleID("com.apple.Safari")

    private func makeEngine(
        sleepWake: FakeSleepWake,
        powerState: FakePowerState = FakePowerState(initiallyVisible: true),
        enumerator: FakeAppEnumerator = FakeAppEnumerator(),
        clock: TestClock = TestClock()
    ) -> ReaperEngine {
        ReaperEngine(
            config: Config(
                settings: Settings.defaults,
                rules: [Self.safari: Rule(timeout: Duration(seconds: 10))]
            ),
            enumerator: enumerator,
            inspector: FakeWindowInspector(default: .none),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: sleepWake,
            powerState: powerState
        )
    }

    @Test("boots asleep — no tick stream until awake")
    func bootsAsleepNoStreamUntilAwake() async {
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateSleep()
        let clock = TestClock()
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: Self.safari, pid: 1)])
        let engine = makeEngine(sleepWake: sleepWake, enumerator: enumerator, clock: clock)

        let task = Task { await engine.run() }
        await Task.yield()

        // While asleep the outer gate keeps us out of runVisibleEpoch —
        // therefore no tick stream subscription should be created.
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })

        for _ in 0 ..< 5 {
            await clock.advance(by: Duration(seconds: 30))
        }
        #expect(await enumerator.callCount == 0, "engine must not enumerate while asleep")

        // Wake → outer loop falls through, runVisibleEpoch starts, tick
        // stream subscribes. The first post-wake tick is consumed by the
        // grace flag; the next tick (after a clock advance) does work.
        await sleepWake.simulateWake()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        await clock.advance(by: Duration(seconds: 1)) // drains grace
        await clock.advance(by: Duration(seconds: 1)) // first real tick
        #expect(await AsyncWait.until { await enumerator.callCount >= 1 })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))
    }

    @Test("willSleep during run tears the tick stream down")
    func willSleepTearsDownTickStream() async {
        let sleepWake = FakeSleepWake()
        let clock = TestClock()
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: Self.safari, pid: 2)])
        let engine = makeEngine(sleepWake: sleepWake, enumerator: enumerator, clock: clock)

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        let countAfterBoot = await enumerator.callCount
        #expect(countAfterBoot >= 1, "startup tick must fire when awake-and-visible")

        // Sleep transition must tear the stream down — proven by the
        // clock observing subscriberCount return to zero.
        await sleepWake.simulateSleep()
        #expect(
            await AsyncWait.until { await clock.subscriberCount == 0 },
            "tick stream must be torn down on willSleep"
        )

        let countBeforeAdvance = await enumerator.callCount

        // Belt-and-braces: even if the stream weren't torn down, advancing
        // the clock would still not produce work (isAsleep gate). The
        // assertion that matters here is the subscriberCount above; this
        // is a redundant check for safety.
        for _ in 0 ..< 10 {
            await clock.advance(by: Duration(seconds: 30))
        }
        #expect(await enumerator.callCount == countBeforeAdvance, "no ticks while asleep")

        // Wake rebuilds the stream.
        await sleepWake.simulateWake()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })
        await clock.advance(by: Duration(seconds: 1)) // drain grace
        await clock.advance(by: Duration(seconds: 1)) // first real tick
        #expect(await AsyncWait.until { await enumerator.callCount > countBeforeAdvance })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))
    }

    @Test("rapid sleep/wake flap does not leak transition waiters")
    func rapidSleepFlapDoesNotLeakWaiters() async {
        let sleepWake = FakeSleepWake()
        let clock = TestClock()
        let engine = makeEngine(sleepWake: sleepWake, clock: clock)

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        for _ in 0 ..< 100 {
            await sleepWake.simulateSleep()
            await sleepWake.simulateWake()
        }
        // Park asleep so we can read the steady-state subscriber count.
        await sleepWake.simulateSleep()
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })

        // At steady state the engine holds exactly one transition
        // subscriber — the outer `waitUntilAwake`.
        #expect(sleepWake.waiterCount <= 1, "waiter count must not grow with rapid flaps; got \(sleepWake.waiterCount)")

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))
    }

    @Test("shutdown unblocks waitUntilAwake")
    func shutdownUnblocksWaitUntilAwake() async {
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateSleep()
        let engine = makeEngine(sleepWake: sleepWake)

        let task = Task { await engine.run() }
        await Task.yield()

        task.cancel()
        #expect(
            await AsyncWait.awaitCompletion(of: task),
            "run must unwind within 2s after cancel even when waiting for awake"
        )
    }

    @Test("isAsleep gate at tick start still suppresses in-flight ticks (belt-and-braces)")
    func inFlightTickSuppressedByIsAsleepGate() async {
        // Models the race: a tick has already been scheduled when the
        // sleep transition arrives. The tick stream teardown is the
        // *primary* defence; this gate is the belt-and-braces fallback.
        let sleepWake = FakeSleepWake()
        await sleepWake.simulateSleep()
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: Self.safari, pid: 3)])
        let terminator = FakeTerminator()
        let engine = ReaperEngine(
            config: Config(
                settings: Settings.defaults,
                rules: [Self.safari: Rule(timeout: Duration(seconds: 1))]
            ),
            enumerator: enumerator,
            inspector: FakeWindowInspector(default: .none),
            terminator: terminator,
            clock: TestClock(),
            sleepWake: sleepWake,
            powerState: FakePowerState()
        )

        let decisions = await engine.tick()
        #expect(decisions.isEmpty, "tick() must short-circuit while asleep even when called directly")
        #expect(await terminator.terminatedPIDs.isEmpty)
    }
}
