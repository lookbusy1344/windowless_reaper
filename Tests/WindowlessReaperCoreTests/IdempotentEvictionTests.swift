import Foundation
import Synchronization
import Testing
import WindowlessReaperCore

/// Tests for the §4.16 idempotent-eviction invariant: cooldown must be
/// durable in the checkpoint *before* the terminator is called, so a crash
/// between the kill and a post-hoc cooldown write cannot let a restart
/// re-terminate the same bundle on the next tick.
///
/// A shared monotonic sequencer counts every checkpoint save and every
/// terminator call. The test asserts: there exists a save with a cooldown
/// entry whose sequence number is strictly less than the first terminate
/// call's sequence number.
@Suite("Idempotent eviction", .timeLimit(.minutes(1)))
struct IdempotentEvictionTests {
    @Test("cooldown is durable in the checkpoint before terminate() is called")
    func cooldownDurableBeforeTerminate() async throws {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .absolute(Duration(seconds: 600))
            ),
            rules: [safari: Rule(timeout: Duration(seconds: 10))]
        )
        let sequencer = Sequencer()
        let terminator = SequencedTerminator(sequencer: sequencer)
        let checkpointer = SequencedCheckpointer(sequencer: sequencer)
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: safari, pid: 11)]),
            inspector: FakeWindowInspector(states: [11: .none]),
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            checkpointer: checkpointer
        )

        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        _ = await engine.tick()

        let saves = checkpointer.savesSnapshot()
        let termSeqs = terminator.callsSnapshot()
        let firstTermSeq = try #require(termSeqs.first?.seq, "terminator was never called")
        let preTermCooldown = saves.first { save in
            save.seq < firstTermSeq && save.snapshot.entries
                .contains(where: { $0.bundleID == safari.value && $0.kind == .cooldown })
        }
        #expect(
            preTermCooldown != nil,
            "no checkpoint save with a cooldown entry preceded the first terminate() call"
        )
    }

    @Test("multi-app eviction batch flushes exactly once before any terminate")
    func batchedEvictionSingleFlush() async throws {
        let safari = BundleID("com.apple.Safari")
        let mail = BundleID("com.apple.mail")
        let notes = BundleID("com.apple.Notes")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .absolute(Duration(seconds: 600))
            ),
            rules: [
                safari: Rule(timeout: Duration(seconds: 10)),
                mail: Rule(timeout: Duration(seconds: 10)),
                notes: Rule(timeout: Duration(seconds: 10)),
            ]
        )
        let sequencer = Sequencer()
        let terminator = SequencedTerminator(sequencer: sequencer)
        let checkpointer = SequencedCheckpointer(sequencer: sequencer)
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [
                RunningApp(bundleID: safari, pid: 11),
                RunningApp(bundleID: mail, pid: 22),
                RunningApp(bundleID: notes, pid: 33),
            ]),
            inspector: FakeWindowInspector(states: [11: .none, 22: .none, 33: .none]),
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            checkpointer: checkpointer
        )

        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        _ = await engine.tick()

        let saves = checkpointer.savesSnapshot()
        let termSeqs = terminator.callsSnapshot()
        let firstTermSeq = try #require(termSeqs.first?.seq, "terminator was never called")

        // Exactly one save precedes the first terminate AND contains a cooldown
        // entry for *every* bundle being evicted. That is the batched
        // pre-evict barrier — coalescing N per-bundle flushes into one.
        let preTermCooldownSaves = saves.filter { save in
            save.seq < firstTermSeq && save.snapshot.entries
                .contains(where: { $0.kind == .cooldown })
        }
        #expect(
            preTermCooldownSaves.count == 1,
            "expected exactly 1 pre-evict checkpoint flush, got \(preTermCooldownSaves.count)"
        )
        let barrier = try #require(preTermCooldownSaves.first)
        let cooldownBundles = Set(
            barrier.snapshot.entries.filter { $0.kind == .cooldown }.map(\.bundleID)
        )
        #expect(cooldownBundles == Set([safari.value, mail.value, notes.value]))
    }

    @Test("vetoed eviction rolls back cooldown to tracked")
    func vetoRollsBackCooldown() async throws {
        let mail = BundleID("com.apple.mail")
        let config = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .absolute(Duration(seconds: 600))
            ),
            rules: [mail: Rule(timeout: Duration(seconds: 10))]
        )
        let terminator = FakeTerminator()
        await terminator.vetoTermination(for: 22)
        let sequencer = Sequencer()
        let checkpointer = SequencedCheckpointer(sequencer: sequencer)
        let clock = TestClock()
        let engine = ReaperEngine(
            config: config,
            enumerator: FakeAppEnumerator(apps: [RunningApp(bundleID: mail, pid: 22)]),
            inspector: FakeWindowInspector(states: [22: .none]),
            terminator: terminator,
            clock: clock,
            sleepWake: FakeSleepWake(),
            powerState: FakePowerState(),
            checkpointer: checkpointer
        )

        _ = await engine.tick()
        await clock.advance(by: Duration(seconds: 20))
        _ = await engine.tick()

        // After veto rollback, the final saved snapshot must show the bundle
        // as tracked. A safe-direction intermediate cooldown is also tolerable
        // (that's the documented crash-window behaviour) but the *final*
        // state must be tracked.
        let saves = checkpointer.savesSnapshot()
        let final = try #require(saves.last)
        let entry = try #require(final.snapshot.entries.first(where: { $0.bundleID == mail.value }))
        #expect(entry.kind == .tracked)
    }
}

// MARK: - Test helpers

private final class Sequencer: Sendable {
    private let counter = Mutex<Int>(0)
    func next() -> Int {
        counter.withLock {
            $0 += 1
            return $0
        }
    }
}

private struct SequencedSave {
    let seq: Int
    let snapshot: TrackerSnapshot
}

private struct SequencedCall {
    let seq: Int
    let pid: pid_t
}

private final class SequencedCheckpointer: Checkpointer {
    private let sequencer: Sequencer
    private let saves = Mutex<[SequencedSave]>([])

    init(sequencer: Sequencer) {
        self.sequencer = sequencer
    }

    func save(_ snapshot: TrackerSnapshot) async throws {
        let seq = sequencer.next()
        saves.withLock { $0.append(SequencedSave(seq: seq, snapshot: snapshot)) }
    }

    func load() async -> TrackerSnapshot? {
        saves.withLock { $0.last?.snapshot }
    }

    func savesSnapshot() -> [SequencedSave] {
        saves.withLock { $0 }
    }
}

private final class SequencedTerminator: Terminator, Sendable {
    private let sequencer: Sequencer
    private let calls = Mutex<[SequencedCall]>([])

    init(sequencer: Sequencer) {
        self.sequencer = sequencer
    }

    func terminate(pid: pid_t) async -> Bool {
        let seq = sequencer.next()
        calls.withLock { $0.append(SequencedCall(seq: seq, pid: pid)) }
        return true
    }

    func callsSnapshot() -> [SequencedCall] {
        calls.withLock { $0 }
    }
}
