import Foundation
import Logging
import Testing
import WindowlessReaperCore

@Suite("Runtime health", .timeLimit(.minutes(1)))
struct RuntimeHealthTests {
    private actor FailingCheckpointer: Checkpointer {
        func save(_ snapshot: TrackerSnapshot) async throws {
            _ = snapshot
            throw SyntheticError.boom
        }

        func load() async -> TrackerSnapshot? {
            nil
        }
    }

    private enum SyntheticError: Error {
        case boom
    }

    @Test("engine runtime health counts ticks, skips, config updates, unknown AX, and checkpoint failures")
    func engineRuntimeHealthCountsActivity() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)]),
            inspector: FakeWindowInspector(states: [11: .unknown]),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            checkpointer: FailingCheckpointer()
        )

        _ = await engine.tick()
        await engine.updateConfig(config)
        await clock.advanceContinuousOnly(by: Duration(seconds: 10))
        _ = await engine.tick()
        await engine.flushCheckpoint(reason: "test")

        let health = await engine.runtimeHealthSnapshot()
        #expect(health.ticks == 2)
        #expect(health.skippedImplicitWake == 1)
        #expect(health.axUnknownInspections == 1)
        #expect(health.configUpdates == 1)
        #expect(health.checkpointSaveFailures == 1)
    }

    private func makeQuietEngine(clock: TestClock, sink: RecordingLogHandler.Sink) -> ReaperEngine {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        let logger = Logger(label: "test.health") { _ in RecordingLogHandler(sink: sink) }
        return ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: []),
            inspector: FakeWindowInspector(states: [:]),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            logger: logger
        )
    }

    @Test("emitHealthSnapshotIfDue emits on first call and again once the interval elapses")
    func emitsRuntimeHealthOnInterval() async {
        let clock = TestClock()
        let sink = RecordingLogHandler.Sink()
        let engine = makeQuietEngine(clock: clock, sink: sink)
        let healthLines = { sink.messages().filter { $0.contains("runtime-health") } }

        await engine.emitHealthSnapshotIfDue(now: clock.now())
        #expect(healthLines().count == 1, "first call must seed a baseline snapshot")

        await clock.advance(by: Duration(seconds: 1800))
        await engine.emitHealthSnapshotIfDue(now: clock.now())
        #expect(healthLines().count == 1, "no emission before the interval elapses")

        await clock.advance(by: Duration(seconds: 1800))
        await engine.emitHealthSnapshotIfDue(now: clock.now())
        let lines = healthLines()
        #expect(lines.count == 2, "second emission once the hour boundary is crossed")

        let last = lines.last ?? ""
        #expect(last.contains("ticks=0"))
        #expect(last.contains("skipped_asleep=0"))
        #expect(last.contains("skipped_implicit_wake=0"))
        #expect(last.contains("ax_unknown_inspections=0"))
        #expect(last.contains("checkpoint_save_failures=0"))
    }

    @Test("tick() does not emit runtime-health — one-shot commands stay quiet")
    func tickAloneIsSilent() async {
        let clock = TestClock()
        let sink = RecordingLogHandler.Sink()
        let engine = makeQuietEngine(clock: clock, sink: sink)

        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 7200))
        _ = await engine.tick()

        let healthLines = sink.messages().filter { $0.contains("runtime-health") }
        #expect(healthLines.isEmpty, "wreaper check / clear call tick() directly and must not log runtime-health")
    }

    @Test("diagnose report renders runtime health")
    func diagnoseReportRendersRuntimeHealth() {
        let health = RuntimeHealthSnapshot(
            ticks: 3,
            skippedAsleep: 0,
            skippedNotVisible: 1,
            skippedGrace: 0,
            skippedImplicitWake: 1,
            configUpdates: 2,
            axUnknownInspections: 4,
            checkpointSaveFailures: 1
        )
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: true,
            configPath: "/tmp/cfg.toml",
            config: nil,
            decisions: [],
            pid: 42,
            health: health
        )

        let text = report.render()
        #expect(text.contains("[runtime-health]"))
        #expect(text.contains("ticks: 3"))
        #expect(text.contains("skipped_not_visible: 1"))
        #expect(text.contains("skipped_implicit_wake: 1"))
        #expect(text.contains("config_updates: 2"))
        #expect(text.contains("ax_unknown_inspections: 4"))
        #expect(text.contains("checkpoint_save_failures: 1"))
    }
}
