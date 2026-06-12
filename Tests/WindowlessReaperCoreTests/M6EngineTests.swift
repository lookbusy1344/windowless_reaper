import Foundation
import Testing
import WindowlessReaperCore

@Suite("M6 — ReaperEngine", .timeLimit(.minutes(1)))
struct M6EngineTests {
    // MARK: - Fixtures

    private func makeConfig(timeout: Int = 60) throws -> Config {
        let safari = BundleID("com.apple.Safari")
        return Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: timeout))]
        )
    }

    private struct Harness {
        let engine: ReaperEngine
        let enumerator: FakeAppEnumerator
        let inspector: FakeWindowInspector
        let terminator: FakeTerminator
        let clock: TestClock
        let sleepWake: FakeSleepWake
    }

    private func makeEngine(
        config: Config,
        apps: [RunningApp] = [],
        windowStates: [pid_t: WindowState] = [:]
    ) async -> Harness {
        let enumerator = FakeAppEnumerator(apps: apps)
        let inspector = FakeWindowInspector(states: windowStates, default: .none)
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
        return Harness(
            engine: engine,
            enumerator: enumerator,
            inspector: inspector,
            terminator: terminator,
            clock: clock,
            sleepWake: sleepWake
        )
    }

    private actor DelayedWindowInspector: WindowInspector {
        private let delay: Swift.Duration
        private let state: WindowState
        private(set) var callCount: Int = 0

        init(delay: Swift.Duration, state: WindowState = .none) {
            self.delay = delay
            self.state = state
        }

        func inspect(pid _: pid_t) async -> WindowInspection {
            callCount += 1
            try? await Task.sleep(for: delay)
            return WindowInspection(state: state)
        }
    }

    // MARK: - Decision wiring

    @Test("engineEmitsExpectedDecisions: ignore → track → evict → cooldown across ticks")
    func engineEmitsExpectedDecisions() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = try makeConfig(timeout: 60)
        let harness = await makeEngine(
            config: config,
            apps: [RunningApp(bundleID: safari, pid: 100)],
            windowStates: [100: .visible]
        )
        let engine = harness.engine
        let inspector = harness.inspector
        let terminator = harness.terminator
        let clock = harness.clock

        // Tick 1: visible window → ignore.
        let t1 = await engine.tick()
        #expect(t1 == [.ignore(safari)])

        // Window closes — bundle becomes windowless. Tick 2 starts tracking.
        await inspector.setState(.none, for: 100)
        let t2 = await engine.tick()
        if case .track(let bid, _) = t2.first {
            #expect(bid == safari)
            #expect(t2.count == 1)
        } else {
            Issue.record("expected .track, got \(t2)")
        }

        // Advance just past timeout. Tick 3 should evict and call terminate.
        await clock.advance(by: Duration(seconds: 61))
        let t3 = await engine.tick()
        if case .evict(let bid, let pids) = t3.first {
            #expect(bid == safari)
            #expect(pids == [100])
        } else {
            Issue.record("expected .evict, got \(t3)")
        }
        #expect(await terminator.terminatedPIDs == [100])

        // Tick 4: post-terminate cooldown.
        let t4 = await engine.tick()
        if case .cooldown(let bid, _) = t4.first {
            #expect(bid == safari)
        } else {
            Issue.record("expected .cooldown, got \(t4)")
        }
    }

    @Test("dry-run never calls terminate()")
    func dryRunSkipsTermination() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = try makeConfig(timeout: 30)
        let harness = await makeEngine(
            config: config,
            apps: [RunningApp(bundleID: safari, pid: 200)],
            windowStates: [200: .none]
        )
        let engine = harness.engine
        let terminator = harness.terminator
        let clock = harness.clock

        // Track → evict path, with dryRun = true.
        _ = await engine.tick(dryRun: true)
        await clock.advance(by: Duration(seconds: 31))
        let decisions = await engine.tick(dryRun: true)

        #expect(decisions.contains { d in if case .evict = d { true } else { false } })
        #expect(await terminator.terminatedPIDs.isEmpty)
    }

    @Test("terminate veto resets the timer (no cooldown)")
    func vetoResetsTimer() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = try makeConfig(timeout: 30)
        let harness = await makeEngine(
            config: config,
            apps: [RunningApp(bundleID: safari, pid: 300)],
            windowStates: [300: .none]
        )
        let engine = harness.engine
        let terminator = harness.terminator
        let clock = harness.clock
        await terminator.vetoTermination(for: 300)

        _ = await engine.tick() // track
        await clock.advance(by: Duration(seconds: 31))
        _ = await engine.tick() // evict → veto → reset

        // Engine called terminate but it returned false; tracker should have
        // re-anchored, not entered cooldown.
        let next = await engine.tick()
        #expect(next.contains { d in if case .track = d { true } else { false } })
        #expect(!next.contains { d in if case .cooldown = d { true } else { false } })
    }

    @Test("grace tick after wake short-circuits the tick")
    func graceTickShortCircuits() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = try makeConfig(timeout: 60)
        let harness = await makeEngine(
            config: config,
            apps: [RunningApp(bundleID: safari, pid: 400)],
            windowStates: [400: .none]
        )
        let engine = harness.engine
        let sleepWake = harness.sleepWake

        await sleepWake.simulateWake()
        let decisions = await engine.tick()
        #expect(decisions.isEmpty, "wake-grace tick must emit no decisions")
    }

    @Test("multi-PID bundle: terminate called on every PID; cooldown only when all accept")
    func multiPIDTermination() async {
        let slack = BundleID("com.tinyspeck.slackmacgap")
        let config = Config(
            settings: Settings.defaults,
            rules: [slack: Rule(timeout: Duration(seconds: 30))]
        )
        let harness = await makeEngine(
            config: config,
            apps: [
                RunningApp(bundleID: slack, pid: 500),
                RunningApp(bundleID: slack, pid: 501),
            ],
            windowStates: [500: .none, 501: .none]
        )
        let engine = harness.engine
        let terminator = harness.terminator
        let clock = harness.clock

        _ = await engine.tick() // track
        await clock.advance(by: Duration(seconds: 31))
        _ = await engine.tick() // evict

        let terminated = await terminator.terminatedPIDs
        #expect(Set(terminated) == Set<pid_t>([500, 501]))
    }

    @Test("hot config swap removes a rule and untracks its bundle")
    func configSwapUntracks() async throws {
        let safari = BundleID("com.apple.Safari")
        let configA = try makeConfig(timeout: 30)
        let configB = Config(settings: Settings.defaults, rules: [:])
        let harness = await makeEngine(
            config: configA,
            apps: [RunningApp(bundleID: safari, pid: 600)],
            windowStates: [600: .none]
        )
        let engine = harness.engine

        _ = await engine.tick() // tracked
        await engine.updateConfig(configB)
        let decisions = await engine.tick()
        // No rule for Safari any more → no decision emitted.
        #expect(decisions.isEmpty)
    }

    @Test("timeout = \"none\" bundle is never inspected via AX")
    func noneTimeoutBundleNotInspected() async {
        let safari = BundleID("com.apple.Safari")
        let mail = BundleID("com.apple.mail")
        let config = Config(
            settings: Settings.defaults,
            rules: [
                safari: Rule(timeout: Duration(seconds: 30)),
                mail: Rule(timeout: nil),
            ]
        )
        let inspector = FakeWindowInspector(states: [100: .none, 200: .none], default: .none)
        let enumerator = FakeAppEnumerator(apps: [
            RunningApp(bundleID: safari, pid: 100),
            RunningApp(bundleID: mail, pid: 200),
        ])
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: inspector,
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        _ = await engine.tick()

        let inspected = await inspector.requestedPIDs
        #expect(inspected == [100], "only the active-rule PID should be inspected; got \(inspected)")
    }

    @Test("unconfigured bundle is never inspected via AX")
    func unconfiguredBundleNotInspected() async {
        let safari = BundleID("com.apple.Safari")
        let mail = BundleID("com.apple.mail")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 30))]
        )
        let inspector = FakeWindowInspector(states: [100: .none, 200: .none], default: .none)
        let enumerator = FakeAppEnumerator(apps: [
            RunningApp(bundleID: safari, pid: 100),
            RunningApp(bundleID: mail, pid: 200),
        ])
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: inspector,
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        _ = await engine.tick()

        let inspected = await inspector.requestedPIDs
        #expect(inspected == [100], "only the configured PID should be inspected; got \(inspected)")
    }

    @Test("buildSnapshots stays serial across multiple PIDs")
    func buildSnapshotsIsSerialAcrossPIDs() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 30))]
        )
        let enumerator = FakeAppEnumerator(apps: [
            RunningApp(bundleID: safari, pid: 700),
            RunningApp(bundleID: safari, pid: 701),
            RunningApp(bundleID: safari, pid: 702),
        ])
        let inspector = DelayedWindowInspector(delay: Swift.Duration.seconds(1))
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: inspector,
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        let start = DispatchTime.now().uptimeNanoseconds
        _ = await engine.tick()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        #expect(elapsedMs >= 2500, "serial inspection across 3 PIDs should take at least ~3s; got \(elapsedMs)ms")
        #expect(await inspector.callCount == 3)
    }
}
