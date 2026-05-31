import Testing
import WindowlessReaperCore

@Suite("CompositeSleepWakeObserver", .timeLimit(.minutes(1)))
struct CompositeSleepWakeTests {
    @Test("consumeGraceTick returns true if any child was pending and drains all")
    func anyPendingReturnsTrue() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        await b.simulateWake()
        let composite = CompositeSleepWakeObserver([a, b])

        #expect(await composite.consumeGraceTick() == true)
        // Both must be drained so a stale flag doesn't bleed into a later tick.
        #expect(await a.consumeGraceTick() == false)
        #expect(await b.consumeGraceTick() == false)
    }

    @Test("consumeGraceTick returns false when no child is pending")
    func nonePendingReturnsFalse() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        let composite = CompositeSleepWakeObserver([a, b])

        #expect(await composite.consumeGraceTick() == false)
    }

    @Test("multiple pending children all drain on one consume")
    func multiplePendingDrainTogether() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        await a.simulateWake()
        await b.simulateWake()
        let composite = CompositeSleepWakeObserver([a, b])

        #expect(await composite.consumeGraceTick() == true)
        #expect(await composite.consumeGraceTick() == false, "second consume must return false — both drained")
    }

    @Test("start and stop forward to every child")
    func lifecycleForwarded() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        let composite = CompositeSleepWakeObserver([a, b])

        await composite.start()
        #expect(await a.started)
        #expect(await b.started)

        await composite.stop()
        #expect(await a.stopped)
        #expect(await b.stopped)
    }

    @Test("empty composite is a valid no-op")
    func emptyCompositeNoOps() async {
        let composite = CompositeSleepWakeObserver([])
        await composite.start()
        #expect(await composite.consumeGraceTick() == false)
        await composite.stop()
    }

    @Test("isAsleep is true when any child reports asleep")
    func isAsleepTrueWhenAnyChild() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        await b.simulateSleep()
        let composite = CompositeSleepWakeObserver([a, b])

        #expect(await composite.isAsleep() == true)
    }

    @Test("isAsleep is false when no child reports asleep")
    func isAsleepFalseWhenNoChild() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        let composite = CompositeSleepWakeObserver([a, b])

        #expect(await composite.isAsleep() == false)
    }

    @Test("transitions: yields current composite state on subscribe, then on changes")
    func transitionsCurrentThenChanges() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        let composite = CompositeSleepWakeObserver([a, b])

        var iterator = composite.transitions().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == true, "both children awake → composite awake")

        await a.simulateSleep()
        let afterSleep = await iterator.next()
        #expect(afterSleep == false, "any child asleep → composite asleep")

        await a.simulateWake()
        let afterWake = await iterator.next()
        #expect(afterWake == true, "all children awake again → composite awake")
    }

    @Test("transitions: awake child reporting first must not emit a spurious awake")
    func transitionsAwakeChildReportingFirst() async {
        // Reproduces the production race that caused a spurious
        // "run resumed — system awake" during sleep:
        // composite is wired [NSWorkspaceSleepWake, IOKitSleepWake]; IOKit
        // observes sleep first while NSWorkspace is still reporting awake.
        // If the still-awake child reports its current state to the new
        // subscription before the asleep child does, the composite must not
        // emit `true` — it must wait until every child has reported.
        let stillAwake = ManualSleepWake(asleep: false)
        let alreadyAsleep = ManualSleepWake(asleep: true)
        let composite = CompositeSleepWakeObserver([stillAwake, alreadyAsleep])

        var iterator = composite.transitions().makeAsyncIterator()
        // Wait for the composite's per-child subscription tasks to attach
        // before emitting — otherwise the emits race the subscribers and
        // are dropped, hanging the iterator.
        while stillAwake.waiterCount == 0 || alreadyAsleep.waiterCount == 0 {
            await Task.yield()
        }
        // Force the buggy ordering: awake child reports first.
        await stillAwake.emit(awake: true)
        await alreadyAsleep.emit(awake: false)
        #expect(await iterator.next() == false, "any child asleep at subscribe → composite asleep")
    }

    @Test("transitions: composite stays asleep while any child is asleep")
    func transitionsCompositeStaysAsleep() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        let composite = CompositeSleepWakeObserver([a, b])

        var iterator = composite.transitions().makeAsyncIterator()
        _ = await iterator.next() // drain initial true

        await a.simulateSleep()
        #expect(await iterator.next() == false)

        // b sleeps too — composite was already asleep, must not re-emit.
        await b.simulateSleep()
        // a wakes — composite still asleep because b is asleep, no emission.
        await a.simulateWake()
        // b wakes — composite becomes awake, that is the next emission.
        await b.simulateWake()
        let next = await iterator.next()
        #expect(next == true, "composite must emit awake only once both children are awake")
    }

    @Test("transitions: empty composite yields one awake value then finishes")
    func transitionsEmpty() async {
        let composite = CompositeSleepWakeObserver([])
        var iterator = composite.transitions().makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(await iterator.next() == nil, "empty composite stream finishes after initial value")
    }

    @Test("isAsleep does not consume or mutate child state")
    func isAsleepDoesNotMutate() async {
        let a = FakeSleepWake()
        let b = FakeSleepWake()
        await a.simulateSleep()
        await b.simulateWake() // arms grace tick on b
        let composite = CompositeSleepWakeObserver([a, b])

        #expect(await composite.isAsleep() == true)
        #expect(await composite.isAsleep() == true, "second call must return the same — read-only")
        // Grace tick on b must remain pending: isAsleep is read-only and idempotent.
        #expect(await b.consumeGraceTick() == true, "isAsleep must not consume grace ticks")
    }
}
