import Foundation
import Testing
import WindowlessReaperCore

// MARK: - WindowState / AppSnapshot

@Suite("AppSnapshot", .timeLimit(.minutes(1)))
struct AppSnapshotTests {
    @Test("fully windowless when every PID has no windows")
    func fullyWindowlessAllNone() {
        let id = BundleID("com.apple.Safari")
        let snap = AppSnapshot(bundleID: id, windowStates: [100: .none, 101: .none])
        #expect(snap.isFullyWindowless)
    }

    @Test("not windowless when any PID has a visible window")
    func notWindowlessWithVisible() {
        let id = BundleID("com.apple.Safari")
        let snap = AppSnapshot(bundleID: id, windowStates: [100: .none, 101: .visible])
        #expect(!snap.isFullyWindowless)
    }

    @Test("not windowless when any PID has a minimised window")
    func notWindowlessWithMinimised() {
        let id = BundleID("com.apple.Safari")
        let snap = AppSnapshot(bundleID: id, windowStates: [100: .none, 101: .minimised])
        #expect(!snap.isFullyWindowless)
    }

    @Test("not windowless when any PID is unknown")
    func notWindowlessWithUnknown() {
        let id = BundleID("com.apple.Safari")
        let snap = AppSnapshot(bundleID: id, windowStates: [100: .none, 101: .unknown])
        #expect(!snap.isFullyWindowless)
    }

    @Test("empty windowStates is not windowless")
    func emptyIsNotWindowless() {
        let id = BundleID("com.apple.Safari")
        let snap = AppSnapshot(bundleID: id, windowStates: [:])
        #expect(!snap.isFullyWindowless)
    }

    @Test("pids exposes key set")
    func pidsExposesKeys() {
        let id = BundleID("com.apple.Safari")
        let snap = AppSnapshot(bundleID: id, windowStates: [100: .none, 200: .visible])
        #expect(snap.pids == Set<pid_t>([100, 200]))
    }
}

// MARK: - FakeAppEnumerator

@Suite("FakeAppEnumerator", .timeLimit(.minutes(1)))
struct FakeAppEnumeratorTests {
    @Test("fakeEnumeratorReturnsConfiguredApps")
    func fakeEnumeratorReturnsConfiguredApps() async {
        let safari = BundleID("com.apple.Safari")
        let mail = BundleID("com.apple.mail")
        let enumerator = FakeAppEnumerator(apps: [
            RunningApp(bundleID: safari, pid: 100),
            RunningApp(bundleID: mail, pid: 200),
        ])

        let result = await enumerator.enumerate()

        #expect(result.count == 2)
        #expect(result.contains(RunningApp(bundleID: safari, pid: 100)))
        #expect(result.contains(RunningApp(bundleID: mail, pid: 200)))
    }

    @Test("setApps replaces the enumerated set")
    func setAppsReplaces() async {
        let safari = BundleID("com.apple.Safari")
        let mail = BundleID("com.apple.mail")
        let enumerator = FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 100)])

        await enumerator.setApps([RunningApp(bundleID: mail, pid: 200)])
        let result = await enumerator.enumerate()

        #expect(result == [RunningApp(bundleID: mail, pid: 200)])
    }
}

// MARK: - FakeWindowInspector

@Suite("FakeWindowInspector", .timeLimit(.minutes(1)))
struct FakeWindowInspectorTests {
    @Test("returns configured state per PID")
    func returnsConfiguredState() async {
        let inspector = FakeWindowInspector(states: [100: .visible, 200: .none])
        #expect(await inspector.windowState(for: 100) == .visible)
        #expect(await inspector.windowState(for: 200) == .none)
    }

    @Test("returns default for unknown PID")
    func returnsDefaultForUnknown() async {
        let inspector = FakeWindowInspector(default: .minimised)
        #expect(await inspector.windowState(for: 999) == .minimised)
    }

    @Test("setState updates per-PID state")
    func setStateUpdates() async {
        let inspector = FakeWindowInspector()
        await inspector.setState(.visible, for: 100)
        #expect(await inspector.windowState(for: 100) == .visible)
    }
}

// MARK: - FakeTerminator

@Suite("FakeTerminator", .timeLimit(.minutes(1)))
struct FakeTerminatorTests {
    @Test("records terminated PIDs in order")
    func recordsTerminations() async {
        let terminator = FakeTerminator()
        let r1 = await terminator.terminate(pid: 100)
        let r2 = await terminator.terminate(pid: 200)
        #expect(r1 && r2)
        #expect(await terminator.terminatedPIDs == [100, 200])
    }

    @Test("vetoed PID returns false and is not recorded")
    func vetoReturnsFalse() async {
        let terminator = FakeTerminator()
        await terminator.vetoTermination(for: 100)
        let result = await terminator.terminate(pid: 100)
        #expect(!result)
        #expect(await terminator.terminatedPIDs.isEmpty)
    }
}

// MARK: - TestClock

@Suite("TestClock", .timeLimit(.minutes(1)))
struct TestClockTests {
    @Test("testClockAdvancesIndependentlyOfWallClock")
    func clockAdvancesIndependentlyOfWallClock() async {
        let clock = TestClock()
        let virtualBefore = await clock.now()
        let wallBefore = ContinuousClock.now

        await clock.advance(by: Duration(seconds: 3600))

        let virtualAfter = await clock.now()
        let wallAfter = ContinuousClock.now

        let virtualElapsed = virtualAfter - virtualBefore
        let wallElapsed = wallAfter - wallBefore

        // Virtual time advances by exactly the requested amount.
        #expect(virtualElapsed == .seconds(3600))
        // Wall clock has barely moved (test runs in microseconds).
        #expect(wallElapsed < .seconds(1))
    }

    @Test("multiple advances accumulate")
    func multipleAdvancesAccumulate() async {
        let clock = TestClock()
        let start = await clock.now()
        await clock.advance(by: Duration(seconds: 60))
        await clock.advance(by: Duration(seconds: 120))
        let end = await clock.now()
        #expect(end - start == .seconds(180))
    }

    @Test("tickStream receives instants on advance")
    func tickStreamReceivesOnAdvance() async {
        let clock = TestClock()
        let stream = clock.tickStream(interval: Duration(seconds: 30))

        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        await clock.advance(by: Duration(seconds: 30))
        await clock.advance(by: Duration(seconds: 30))

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first != nil)
        #expect(second != nil)
        if let f = first, let s = second {
            #expect(s - f == .seconds(30))
        }
    }
}

// MARK: - SleepWakeObserver

@Suite("FakeSleepWake", .timeLimit(.minutes(1)))
struct SleepWakeObserverTests {
    @Test("sleepWakeObserverEmitsGraceTickFlag")
    func sleepWakeObserverEmitsGraceTickFlag() async {
        let observer = FakeSleepWake()

        // No wake yet — no grace tick.
        #expect(await observer.consumeGraceTick() == false)

        await observer.simulateWake()

        // First call after wake returns true; second returns false (consumed).
        #expect(await observer.consumeGraceTick() == true)
        #expect(await observer.consumeGraceTick() == false)
    }

    @Test("start and stop flip lifecycle flags")
    func startStopLifecycle() async {
        let observer = FakeSleepWake()
        #expect(await observer.started == false)
        #expect(await observer.stopped == false)
        await observer.start()
        await observer.stop()
        #expect(await observer.started)
        #expect(await observer.stopped)
    }

    @Test("repeated wakes re-arm the grace flag")
    func repeatedWakesReArm() async {
        let observer = FakeSleepWake()
        await observer.simulateWake()
        _ = await observer.consumeGraceTick()
        await observer.simulateWake()
        #expect(await observer.consumeGraceTick() == true)
    }
}
