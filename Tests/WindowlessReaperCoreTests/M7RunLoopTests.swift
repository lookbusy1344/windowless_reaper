import Foundation
import Testing
import WindowlessReaperCore

@Suite("M7 — ReaperEngine.run loop", .timeLimit(.minutes(1)))
struct M7RunLoopTests {
    private func makeRule(_ seconds: Int) -> Rule {
        Rule(timeout: Duration(seconds: seconds))
    }

    @Test("startupTickRunsBeforeFirstInterval: first scan happens at t=0, not after pollInterval")
    func startupTickRunsBeforeFirstInterval() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: makeRule(10)]
        )
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)])
        let inspector = FakeWindowInspector(states: [11: .none])
        let terminator = FakeTerminator()
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        let task = Task { await engine.run() }
        await Task.yield()

        #expect(await AsyncWait.until { await enumerator.callCount >= 1 })
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        // No clock advance yet. With the startup tick, tracking has already
        // begun at t=0. A single advance past the timeout should now suffice
        // to evict — previously this required two advances (one to observe,
        // one to evict after the timeout).
        await clock.advance(by: Duration(seconds: 20))
        #expect(await AsyncWait.until { await enumerator.callCount >= 2 })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        let killed = await terminator.terminatedPIDs
        #expect(
            killed.contains(11),
            "startup tick must observe pid 11 at t=0 so one timeout-spanning advance evicts it"
        )
    }

    @Test("runLoopHonoursCancellation: cancel returns promptly")
    func runLoopHonoursCancellation() async {
        let config = Config(settings: Settings.defaults, rules: [:])
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(),
            inspector: FakeWindowInspector(),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })
        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task), "run loop did not honour cancellation within 2s")
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })
        #expect(await clock.terminationCount >= 1)
    }

    @Test("graceTickSkippedAfterWake: first post-wake tick performs no work")
    func graceTickSkippedAfterWake() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: makeRule(10)]
        )
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 1)])
        let inspector = FakeWindowInspector(states: [1: .none])
        let terminator = FakeTerminator()
        let clock = TestClock()
        let sleepWake = FakeSleepWake()
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: sleepWake,
            powerState: FakePowerState()
        )

        await sleepWake.simulateWake()
        let task = Task { await engine.run() }
        await Task.yield()

        // Tick 1: consumed by wake grace — no tracking happens.
        await clock.advance(by: Duration(seconds: 1))

        // Tick 2 starts tracking; we have not yet reached the timeout.
        await clock.advance(by: Duration(seconds: 5))

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        let killed = await terminator.terminatedPIDs
        #expect(killed.isEmpty, "wake grace must prevent any termination on the first post-wake tick")
    }

    @Test("configHotReloadAppliesWithoutRestart: removed rule untracks; added rule activates")
    func configHotReloadAppliesWithoutRestart() async {
        let safari = BundleID("com.apple.Safari")
        let mail = BundleID("com.apple.mail")
        let configA = Config(
            settings: Settings.defaults,
            rules: [safari: makeRule(10)]
        )
        let configB = Config(
            settings: Settings.defaults,
            rules: [mail: makeRule(10)]
        )
        let enumerator = FakeAppEnumerator(apps: [
            RunningApp(bundleID: safari, pid: 11),
            RunningApp(bundleID: mail, pid: 22),
        ])
        let inspector = FakeWindowInspector(states: [11: .none, 22: .none])
        let terminator = FakeTerminator()
        let clock = TestClock()
        let engine = ReaperEngine(
            config: configA,
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        // Tick 1 under configA — Safari starts tracking.
        await clock.advance(by: Duration(seconds: 1))
        #expect(await AsyncWait.until { await enumerator.callCount >= 2 })

        // Hot-swap to configB.
        await engine.updateConfig(configB)

        // Advance well past the (former) Safari timeout. Tick 2 sees the
        // new config: Safari is untracked, Mail starts tracking.
        await clock.advance(by: Duration(seconds: 5))
        #expect(await AsyncWait.until { await enumerator.callCount >= 3 })

        // Tick 3 — Mail's elapsed exceeds its 10s timeout.
        await clock.advance(by: Duration(seconds: 20))
        #expect(await AsyncWait.until { await enumerator.callCount >= 4 })
        _ = await engine.tick()

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        let killed = await terminator.terminatedPIDs
        #expect(!killed.contains(11), "safari rule was removed; pid 11 must not be terminated")
        #expect(killed.contains(22), "mail rule was added and exceeded its timeout; pid 22 should be terminated")
    }

    @Test("dryRunHotReloadOffEnablesEvictions: dry_run flipped false → true → false honours latest config")
    func dryRunHotReloadOffEnablesEvictions() async {
        let safari = BundleID("com.apple.Safari")
        let dryConfig = Config(
            settings: Settings(
                pollInterval: Settings.defaults.pollInterval,
                logLevel: "info",
                dryRun: true,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: makeRule(10)]
        )
        let liveConfig = Config(
            settings: Settings(
                pollInterval: Settings.defaults.pollInterval,
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: makeRule(10)]
        )
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)])
        let inspector = FakeWindowInspector(states: [11: .none])
        let terminator = FakeTerminator()
        let clock = TestClock()
        let engine = ReaperEngine(
            config: dryConfig,
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        // Tick 1 under dry-run — Safari starts tracking but no termination.
        await clock.advance(by: Duration(seconds: 1))
        #expect(await AsyncWait.until { await enumerator.callCount >= 2 })

        // Advance past the timeout while still dry-run — would-be eviction
        // must not call the terminator.
        await clock.advance(by: Duration(seconds: 20))

        var killed = await terminator.terminatedPIDs
        #expect(killed.isEmpty, "dry-run must suppress termination while config.dryRun = true")

        // Flip dry_run off via hot reload.
        await engine.updateConfig(liveConfig)

        // Advance again past the timeout window; the next tick should now
        // honour the live config and evict pid 11.
        await clock.advance(by: Duration(seconds: 20))
        #expect(await AsyncWait.until { await enumerator.callCount >= 4 })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        killed = await terminator.terminatedPIDs
        #expect(killed.contains(11), "after flipping dry_run false, pid 11 should be terminated")
    }

    @Test("pollIntervalHotReload: interval change recreates the tick stream without restart")
    func pollIntervalHotReload() async {
        let safari = BundleID("com.apple.Safari")
        let initial = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: makeRule(10)]
        )
        let reloaded = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 60),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: makeRule(10)]
        )

        let clock = TestClock()
        let engine = ReaperEngine(
            config: initial,
            enumerator: FakeAppEnumerator(),
            inspector: FakeWindowInspector(),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )
        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        // First tick under 30s interval.
        await clock.advance(by: Duration(seconds: 30))

        // Hot-swap pollInterval to 60s.
        await engine.updateConfig(reloaded)

        // The next advance still triggers, and the engine recreates its stream
        // when it observes the changed interval. Subsequent ticks continue to
        // flow via the new stream.
        await clock.advance(by: Duration(seconds: 60))
        await clock.advance(by: Duration(seconds: 60))

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))
        // Lack of hang/crash is the assertion; the loop must not deadlock when
        // the captured interval changes mid-run.
    }

    @Test("pressureChangeRecreatesTickStream: changing effective interval tears down the old stream")
    func pressureChangeRecreatesTickStream() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0),
                adaptivePressure: true
            ),
            rules: [safari: makeRule(10)]
        )
        let clock = TestClock()
        let pressure = FakePowerPressure(.nominal)
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)]),
            inspector: FakeWindowInspector(states: [11: .none]),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            pressure: pressure
        )

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        pressure.set(PressureSnapshot(source: .battery, lowPowerMode: false, thermalState: .nominal))
        await clock.advance(by: Duration(seconds: 30))

        #expect(await AsyncWait.until { await clock.terminationCount >= 1 })

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))
        #expect(await AsyncWait.until { await clock.subscriberCount == 0 })
    }
}
