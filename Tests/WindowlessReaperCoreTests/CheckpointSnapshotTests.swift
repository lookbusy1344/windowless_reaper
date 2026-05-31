import Foundation
import Testing
@testable import WindowlessReaperCore

/// Round-trip tests for `TrackerSnapshot` via the engine's
/// `checkpointSnapshot()` / `restoreCheckpoint(_:)` actor methods.
///
/// Snapshots encode *durations*, not `SuspendingClock` instants — see
/// power_man_best_practices.md §2.18. The invariant pinned here is that
/// elapsed time encoded into a snapshot survives a save → load round-trip
/// and re-anchors against the destination clock such that the engine
/// resumes treating each bundle as having been windowless for the same
/// amount of *user-visible* time.
@Suite("Checkpoint snapshot", .timeLimit(.minutes(1)))
struct CheckpointSnapshotTests {
    private func makeEngine(config: Config, clock: TestClock, app: BundleID, pid: pid_t = 11) -> ReaperEngine {
        ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: app, pid: pid)]),
            inspector: FakeWindowInspector(states: [pid: .none]),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )
    }

    @Test("empty tracker round-trips to empty snapshot")
    func emptySnapshotRoundTrip() async throws {
        let engine = ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [:]),
            enumerator: FakeAppEnumerator(apps: []),
            inspector: FakeWindowInspector(states: [:]),
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )
        let snap = await engine.checkpointSnapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.version == TrackerSnapshot.currentVersion)

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
        #expect(decoded == snap)
    }

    @Test("tracked bundles preserve elapsed time across encode/restore")
    func trackedElapsedSurvivesRoundTrip() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: [safari: Rule(timeout: Duration(seconds: 300))]
        )

        let clockA = TestClock()
        let engineA = makeEngine(config: config, clock: clockA, app: safari)
        _ = await engineA.tick()
        await clockA.advance(by: Duration(seconds: 120))
        _ = await engineA.tick()

        let saved = await engineA.checkpointSnapshot()
        let entry = try #require(saved.entries.first)
        #expect(entry.bundleID == safari.value)
        #expect(entry.kind == .tracked)
        #expect(entry.timeoutSeconds == 300)
        #expect(entry.elapsedSeconds >= 119 && entry.elapsedSeconds <= 121)

        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
        let clockB = TestClock()
        let engineB = makeEngine(config: config, clock: clockB, app: safari)
        await engineB.restoreCheckpoint(decoded)

        // Need ~180s more to cross the 300s timeout from the restored 120s.
        await clockB.advance(by: Duration(seconds: 181))
        let decisions = await engineB.tick()
        #expect(decisions.contains { if case .evict = $0 { true } else { false } },
                "restored tracker did not preserve elapsed windowless time")
    }

    @Test("cooldown remaining survives round-trip")
    func cooldownRemainingSurvivesRoundTrip() async throws {
        let mail = BundleID("com.apple.mail")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .absolute(Duration(seconds: 600))
            ),
            rules: [mail: Rule(timeout: Duration(seconds: 60))]
        )

        let clockA = TestClock()
        let engineA = makeEngine(config: config, clock: clockA, app: mail, pid: 22)
        _ = await engineA.tick()
        await clockA.advance(by: Duration(seconds: 90))
        _ = await engineA.tick()

        let saved = await engineA.checkpointSnapshot()
        let entry = try #require(saved.entries.first)
        #expect(entry.kind == .cooldown)
        #expect(entry.elapsedSeconds >= 595 && entry.elapsedSeconds <= 600)

        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
        #expect(decoded == saved)
    }

    @Test("future-version snapshot is decodable (forward compatibility hook)")
    func futureVersionDecodes() throws {
        // The on-disk loader (Phase 3b) will inspect `version` and refuse
        // to restore from an unknown version — but the type itself must
        // decode any well-formed payload, otherwise the loader can never
        // see the version field to make that decision.
        let future = TrackerSnapshot(entries: [], version: 99)
        let data = try JSONEncoder().encode(future)
        let decoded = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
        #expect(decoded.version == 99)
    }
}
