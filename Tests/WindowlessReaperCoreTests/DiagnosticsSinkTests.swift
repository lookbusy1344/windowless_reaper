import Foundation
import Testing
import WindowlessReaperCore

private func sampleHealth(ticks: Int = 1) -> RuntimeHealthSnapshot {
    RuntimeHealthSnapshot(
        ticks: ticks,
        skippedAsleep: 0,
        skippedNotVisible: 0,
        skippedGrace: 0,
        skippedImplicitWake: 0,
        configUpdates: 0,
        axUnknownInspections: 0,
        checkpointSaveFailures: 0
    )
}

@Suite("PersistedDecision projection", .timeLimit(.minutes(1)))
struct PersistedDecisionTests {
    @Test("ignore round-trips kind and bundle ID")
    func ignoreRoundTrip() {
        let decision = Decision.ignore(BundleID("com.apple.Safari"))
        let persisted = PersistedDecision(decision)
        #expect(persisted.kind == .ignore)
        #expect(persisted.bundleID == "com.apple.Safari")
        #expect(persisted.pids == nil)
    }

    @Test("evict preserves the sorted PID set")
    func evictPreservesPIDs() {
        let decision = Decision.evict(BundleID("com.apple.mail"), pids: [42, 7, 100])
        let persisted = PersistedDecision(decision)
        #expect(persisted.kind == .evict)
        #expect(persisted.pids == [7, 42, 100])
        // toDecision rebuilds the same eviction (instant-free case is lossless).
        #expect(persisted.toDecision() == decision)
    }

    @Test("track/cooldown survive the instant-dropping round-trip for rendering")
    func instantBearingCasesRoundTrip() {
        let now = SuspendingClock.now
        let track = PersistedDecision(.track(BundleID("a.b"), since: now))
        #expect(track.kind == .track)
        #expect(track.toDecision(now: now) == .track(BundleID("a.b"), since: now))

        let cooldown = PersistedDecision(.cooldown(BundleID("a.b"), until: now))
        #expect(cooldown.kind == .cooldown)
        #expect(cooldown.toDecision(now: now) == .cooldown(BundleID("a.b"), until: now))
    }

    @Test("DiagnosticsSnapshot JSON round-trips with decisions and health")
    func snapshotCodableRoundTrip() throws {
        let snapshot = DiagnosticsSnapshot(
            decisions: [
                PersistedDecision(.ignore(BundleID("x"))),
                PersistedDecision(.evict(BundleID("y"), pids: [1, 2])),
            ],
            health: sampleHealth(ticks: 5)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}

@Suite("FileDiagnosticsSink", .timeLimit(.minutes(1)))
struct FileDiagnosticsSinkTests {
    private func makeSink() throws -> (FileDiagnosticsSink, TemporaryDirectory) {
        let tmp = try TemporaryDirectory()
        return (FileDiagnosticsSink(url: tmp.child("diagnostics.json")), tmp)
    }

    @Test("write → read round-trips decisions and health")
    func roundTrip() async throws {
        let (sink, tmp) = try makeSink()
        defer { tmp.cleanup() }
        let decisions: [Decision] = [
            .ignore(BundleID("com.apple.Safari")),
            .evict(BundleID("com.apple.mail"), pids: [99]),
        ]
        let health = sampleHealth(ticks: 3)
        await sink.write(decisions: decisions, health: health)
        let read = await sink.read()
        #expect(read?.decisions == decisions.map(PersistedDecision.init))
        #expect(read?.health == health)
    }

    @Test("read returns nil when the sidecar is absent")
    func readMissingReturnsNil() async throws {
        let (sink, tmp) = try makeSink()
        defer { tmp.cleanup() }
        #expect(await sink.read() == nil)
    }

    @Test("read returns nil for corrupt JSON")
    func readCorruptReturnsNil() async throws {
        let (sink, tmp) = try makeSink()
        defer { tmp.cleanup() }
        try "not json".write(to: tmp.child("diagnostics.json"), atomically: true, encoding: .utf8)
        #expect(await sink.read() == nil)
    }

    @Test("engine persists decisions and health to the sidecar after a tick")
    func enginePersistsAfterTick() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let sink = FileDiagnosticsSink(url: tmp.child("diagnostics.json"))

        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 60))]
        )
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 100)]),
            inspector: FakeWindowInspector(states: [100: .none], default: .none),
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            diagnosticsSink: sink
        )

        let decisions = await engine.tick()
        #expect(!decisions.isEmpty) // windowless app with a rule → tracked
        let persisted = await sink.read()
        #expect(persisted?.decisions == decisions.map(PersistedDecision.init))
        #expect(persisted?.health?.ticks == 1)
    }
}
