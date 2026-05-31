import AppKit
import Foundation
import Logging
import Synchronization

/// Production `SleepWakeObserver` backed by `NSWorkspace` notifications.
///
/// On `didWakeNotification` we set a one-shot grace flag that the engine
/// consumes on its next tick and uses to skip exactly one cycle — AX window
/// lists take a few seconds to repopulate after wake, and without the skip
/// we'd race app restoration and risk mass eviction.
///
/// State is held in a `Mutex` rather than actor-isolated so `transitions()`
/// (called from inside `ReaperEngine`'s task group) does not require an
/// actor hop on the hot path, matching the shape of `NSWorkspaceScreenWake`
/// and `IOKitSleepWake`.
public final class NSWorkspaceSleepWake: SleepWakeObserver {
    private struct State {
        var graceTickPending: Bool = false
        var asleep: Bool = false
        var tokens: [any NSObjectProtocol] = []
        var waiters: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State> = Mutex(State())
    private let logger: Logger

    public init(logger: Logger = Logger(label: "wreaper.sleepwake")) {
        self.logger = logger
    }

    public func start() async {
        let center = NSWorkspace.shared.notificationCenter
        if state.withLock({ !$0.tokens.isEmpty }) { return }

        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWake()
        }
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillSleep()
        }
        state.withLock { $0.tokens = [wake, sleep] }
    }

    public func stop() async {
        let center = NSWorkspace.shared.notificationCenter
        let snapshot = state.withLock { s -> (tokens: [any NSObjectProtocol], waiters: [AsyncStream<Bool>.Continuation]) in
            let tokens = s.tokens
            let waiters = Array(s.waiters.values)
            s.tokens.removeAll()
            s.waiters.removeAll()
            s.asleep = false
            s.graceTickPending = false
            return (tokens, waiters)
        }
        for token in snapshot.tokens {
            center.removeObserver(token)
        }
        for w in snapshot.waiters {
            w.finish()
        }
    }

    public func consumeGraceTick() -> Bool {
        state.withLock { s in
            let pending = s.graceTickPending
            s.graceTickPending = false
            return pending
        }
    }

    public func isAsleep() -> Bool {
        state.withLock { $0.asleep }
    }

    public func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = state.withLock { s -> Bool in
                s.waiters[id] = continuation
                return !s.asleep
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.waiters[id] = nil }
            }
        }
    }

    private func handleWake() {
        let waiters = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            let changed = s.asleep
            s.asleep = false
            s.graceTickPending = true
            return changed ? Array(s.waiters.values) : []
        }
        logger.notice("system wake — next tick will be skipped (AX grace period)")
        for w in waiters {
            w.yield(true)
        }
    }

    private func handleWillSleep() {
        let waiters = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            let changed = !s.asleep
            s.asleep = true
            return changed ? Array(s.waiters.values) : []
        }
        logger.notice("system will sleep")
        for w in waiters {
            w.yield(false)
        }
    }
}
