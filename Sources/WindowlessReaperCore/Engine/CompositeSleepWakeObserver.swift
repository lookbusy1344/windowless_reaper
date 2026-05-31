import Foundation
import Synchronization

/// Combines multiple `SleepWakeObserver`s into one. Production wiring uses
/// this to OR the NSWorkspace observer (user wake) with the IOKit observer
/// (kernel power notifications, including dark wake on AC) so a grace skip
/// fires regardless of which API got the signal.
///
/// `consumeGraceTick` queries *every* child even after the first `true`, so
/// a flag armed on one observer cannot survive into the next tick on the
/// strength of another observer's silence.
public final class CompositeSleepWakeObserver: SleepWakeObserver {
    private let children: [any SleepWakeObserver]

    public init(_ children: [any SleepWakeObserver]) {
        self.children = children
    }

    /// If a third child is added, switch start/stop to withTaskGroup to
    /// parallelise the calls — the serial await is fine for two children.
    public func start() async {
        for child in children {
            await child.start()
        }
    }

    public func stop() async {
        for child in children {
            await child.stop()
        }
    }

    public func consumeGraceTick() async -> Bool {
        var anyPending = false
        for child in children where await child.consumeGraceTick() {
            anyPending = true
        }
        return anyPending
    }

    /// Read-only and idempotent — short-circuits on the first asleep child.
    /// Unlike `consumeGraceTick`, there's no flag to drain.
    public func isAsleep() async -> Bool {
        for child in children where await child.isAsleep() {
            return true
        }
        return false
    }

    /// Merge children's transition streams. The composite is "awake" only
    /// when every child is awake — matches `isAsleep()`'s any-asleep
    /// semantics. Emits the composite state once every child has reported
    /// at least once (so a still-lagging awake child cannot mask another
    /// child's already-observed sleep), then on every change. Cancellation
    /// of the returned stream cancels every child subscription — no leaked
    /// waiters on teardown.
    public func transitions() -> AsyncStream<Bool> {
        let children = children
        return AsyncStream { continuation in
            guard !children.isEmpty else {
                continuation.yield(true)
                continuation.finish()
                return
            }
            // Per-child awake state + last emitted composite, kept in one
            // Mutex so each child event computes/transmits under a single
            // lock and ordering is deterministic. `states[i] == nil` means
            // child `i` has not yet reported — the composite stays silent
            // until every slot is filled. Seeding to `true` would have
            // emitted a spurious awake whenever an awake child reported
            // before an already-asleep child during subscription.
            struct CompositeState {
                var states: [Bool?]
                var lastEmitted: Bool?
            }
            let state = Mutex<CompositeState>(CompositeState(
                states: Array(repeating: nil, count: children.count),
                lastEmitted: nil
            ))

            let tasks: [Task<Void, Never>] = children.enumerated().map { index, child in
                let child = child
                let body: @Sendable () async -> Void = {
                    for await awake in child.transitions() {
                        let toEmit = state.withLock { s -> Bool? in
                            s.states[index] = awake
                            guard let resolved = s.states.allUnwrapped() else { return nil }
                            let composite = resolved.allSatisfy(\.self)
                            guard s.lastEmitted != composite else { return nil }
                            s.lastEmitted = composite
                            return composite
                        }
                        if let toEmit { continuation.yield(toEmit) }
                    }
                }
                return Task(operation: body)
            }

            continuation.onTermination = { _ in
                for t in tasks {
                    t.cancel()
                }
            }
        }
    }
}

private extension Array {
    /// Returns the unwrapped values if every element is non-nil, else nil.
    func allUnwrapped<Wrapped>() -> [Wrapped]? where Element == Wrapped? {
        var out: [Wrapped] = []
        out.reserveCapacity(count)
        for e in self {
            guard let e else { return nil }
            out.append(e)
        }
        return out
    }
}
