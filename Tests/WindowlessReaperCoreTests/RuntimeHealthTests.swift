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

    @Test("engine runtime health accumulates unreadable-window reads from the inspector")
    func engineCountsUnreadableWindows() async {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        // The app classifies as `.visible` (an unreadable minimised attribute
        // falls back to not-minimised) yet the two failed reads must surface in
        // the health counter rather than vanishing.
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)]),
            inspector: FakeWindowInspector(states: [11: .visible], unreadableWindows: [11: 2]),
            terminator: FakeTerminator(),
            clock: TestClock(),
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState()
        )

        _ = await engine.tick()
        _ = await engine.tick()

        let health = await engine.runtimeHealthSnapshot()
        #expect(health.axUnreadableWindows == 4, "two failed reads per tick across two ticks")
        #expect(health.axUnknownInspections == 0, "a visible app with unreadable windows is not unknown")
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

    /// Pull a `key=value` integer out of a `runtime-health` log line.
    private func metric(_ key: String, in line: String) -> Int? {
        line.split(separator: " ")
            .first { $0.hasPrefix("\(key)=") }
            .flatMap { Int($0.dropFirst(key.count + 1)) }
    }

    @Test("post-wake runtime-health dump keeps skipped_grace in step with skipped_asleep")
    func postWakeHealthDumpNotSkewed() async {
        let clock = TestClock()
        let sink = RecordingLogHandler.Sink()
        let sleepWake = FakeSleepWake()
        let logger = Logger(label: "test.health") { _ in RecordingLogHandler(sink: sink) }
        let engine = ReaperEngine(
            config: Config(settings: Settings.defaults, rules: [:]),
            enumerator: FakeAppEnumerator(apps: []),
            inspector: FakeWindowInspector(states: [:]),
            terminator: FakeTerminator(),
            clock: clock,
            sleepWake: sleepWake,
            powerState: FakePowerState(),
            logger: logger
        )
        func healthLines() -> [String] {
            sink.messages().filter { $0.contains("runtime-health") }
        }

        let task = Task { await engine.run() }
        await Task.yield()
        #expect(await AsyncWait.until { sink.messages().contains { $0.contains("runtime-health") } }, "baseline snapshot must emit at run start")
        #expect(await AsyncWait.until { await clock.subscriberCount > 0 })

        // Sleep: the visible epoch tears down and the run loop records one
        // skipped_asleep before parking in waitUntilAwake. Wait for the
        // suspend log so the skip is counted before we wake — otherwise the
        // loop may observe the wake first and skip the asleep branch entirely.
        await sleepWake.simulateSleep()
        #expect(await AsyncWait.until { sink.messages().contains { $0.contains("run suspended — system asleep") } })

        // Wall time elapses past the health-log interval so the first
        // post-wake snapshot is due the moment the engine resumes.
        await clock.advance(by: Duration(seconds: 3600))

        // Wake arms the grace tick; the engine re-enters the visible epoch.
        await sleepWake.simulateWake()
        #expect(await AsyncWait.until { sink.messages().count(where: { $0.contains("runtime-health") }) >= 2 }, "post-wake snapshot must emit once the interval has elapsed")

        task.cancel()
        #expect(await AsyncWait.awaitCompletion(of: task))

        let last = healthLines().last ?? ""
        let asleep = metric("skipped_asleep", in: last)
        let grace = metric("skipped_grace", in: last)
        #expect(asleep == 1, "expected one recorded sleep, line: \(last)")
        #expect(
            grace == asleep,
            "post-wake dump must not show skipped_grace lagging skipped_asleep — the grace skip is counted inside tick(), so the dump must follow the tick. line: \(last)"
        )
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
            axUnreadableWindows: 5,
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
        #expect(text.contains("ax_unreadable_windows: 5"))
        #expect(text.contains("checkpoint_save_failures: 1"))
    }
}
