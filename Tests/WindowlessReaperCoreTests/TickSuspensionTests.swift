import Foundation
import Testing
import WindowlessReaperCore

@Suite("Tick suspension during dark wake", .timeLimit(.minutes(1)))
struct TickSuspensionTests {
    private func makeEngine(
        powerState: FakePowerState,
        enumerator: FakeAppEnumerator = FakeAppEnumerator(),
        clock: TestClock = TestClock()
    ) -> ReaperEngine {
        ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [:]),
            enumerator: enumerator,
            inspector: FakeWindowInspector(),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: powerState
        )
    }

    @Test("boots invisible — no ticks until visible")
    func bootsInvisibleNoTicksUntilVisible() async {
        let safari = BundleID("com.apple.Safari")
        let rule = Rule(timeout: Duration(seconds: 10))
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 1)])
        let clock = TestClock()
        let powerState = FakePowerState(initiallyVisible: false)
        let engine = ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [safari: rule]),
            enumerator: enumerator,
            inspector: FakeWindowInspector(default: .none),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: powerState
        )

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })

        // Advance clock several intervals while invisible — engine must not tick.
        for _ in 0 ..< 5 {
            await clock.advance(by: Duration(seconds: 30))
        }

        let enumeratedBeforeVisible = await enumerator.callCount
        #expect(enumeratedBeforeVisible == 0, "engine must not enumerate while invisible")

        // Flip visible and let one tick fire.
        powerState.setVisible(true)
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })
        await clock.advance(by: Duration(seconds: 1))
        #expect(await AsyncWait.until { await enumerator.callCount >= 1 })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        let enumeratedAfterVisible = await enumerator.callCount
        #expect(enumeratedAfterVisible >= 1, "engine must enumerate after becoming visible")
    }

    @Test("flip to invisible during run cancels tick loop")
    func flipToInvisibleCancelsTickLoop() async {
        let safari = BundleID("com.apple.Safari")
        let rule = Rule(timeout: Duration(seconds: 10))
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 2)])
        let clock = TestClock()
        let powerState = FakePowerState(initiallyVisible: true)
        let engine = ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [safari: rule]),
            enumerator: enumerator,
            inspector: FakeWindowInspector(default: .none),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: powerState
        )

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        // Startup tick fires immediately (visible boot).
        let countAfterBoot = await enumerator.callCount
        #expect(countAfterBoot >= 1, "startup tick must fire when visible")

        // Flip invisible.
        powerState.setVisible(false)
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })

        let countBeforeAdvance = await enumerator.callCount

        // Advance 5 intervals — no new ticks should fire.
        for _ in 0 ..< 5 {
            await clock.advance(by: Duration(seconds: 30))
        }

        let countAfterInvisible = await enumerator.callCount
        #expect(countAfterInvisible == countBeforeAdvance, "tick loop must stop while invisible")

        // Flip back visible, advance one interval.
        powerState.setVisible(true)
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })
        await clock.advance(by: Duration(seconds: 1))
        #expect(await AsyncWait.until { await enumerator.callCount > countAfterInvisible })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        let countAfterRevisible = await enumerator.callCount
        #expect(countAfterRevisible > countAfterInvisible, "tick loop must resume after becoming visible again")
    }

    @Test("rapid visibility flap does not leak waiters")
    func rapidFlapDoesNotLeakWaiters() async {
        let powerState = FakePowerState(initiallyVisible: true)
        let clock = TestClock()
        let engine = makeEngine(powerState: powerState, clock: clock)

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        for _ in 0 ..< 100 {
            powerState.setVisible(false)
            powerState.setVisible(true)
        }
        powerState.setVisible(false)
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })

        // At steady state (waiting for visible), the engine holds exactly one
        // transition subscription (the outer-loop waitUntilVisible).
        let count = powerState.waiterCount
        #expect(count <= 1, "waiter count must not grow with rapid flaps; got \(count)")

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))
    }

    @Test("shutdown unblocks waitUntilVisible")
    func shutdownUnblocksWaitUntilVisible() async {
        let powerState = FakePowerState(initiallyVisible: false)
        let clock = TestClock()
        let engine = makeEngine(powerState: powerState, clock: clock)

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })

        task.cancel()

        #expect(await AsyncWait.awaitCompletion(of: task), "run must unwind within 2s after cancel even when waiting for visible")
    }

    @Test("existing in-tick gate is independently testable")
    func existingInTickGateIndependent() async {
        let powerState = FakePowerState(initiallyVisible: false)
        let enumerator = FakeAppEnumerator(apps: [])
        let engine = makeEngine(powerState: powerState, enumerator: enumerator)

        let decisions = await engine.tick()
        #expect(decisions.isEmpty, "in-tick gate must short-circuit when not user-visible")
    }
}
