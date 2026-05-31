import AppKit
import CoreGraphics
import Foundation
import Logging
import Synchronization

/// Production `SystemPowerStateObserver` backed by `NSWorkspace` screen
/// sleep/wake notifications and `CGDisplayIsAsleep` for the initial state.
///
/// `NSWorkspace.screensDidSleepNotification` fires when the display hardware
/// powers off — this covers both dark wake (CPU running, lid closed) and
/// user-requested display sleep. `screensDidWakeNotification` fires only on
/// full user wake, so the gate stays closed for the entire dark-wake window.
///
/// **Seed assumption**: the initial state is seeded from
/// `CGMainDisplayID()`. If a secondary display is asleep while the main is
/// awake at startup, the seed reports "visible". This corrects on the next
/// `screensDidSleepNotification`; no known reports of a misfire.
///
/// **Lifecycle**: call `start()` once before the engine loop, `stop()` once
/// after. `isUserVisible()` is safe to call at any time; it reads a
/// `Mutex`-guarded bool and requires no actor hop.
public final class NSWorkspaceScreenWake: SystemPowerStateObserver {
    private struct State {
        var visible: Bool
        var waiters: [UUID: AsyncStream<Bool>.Continuation] = [:]
        var tokens: [any NSObjectProtocol] = []
    }

    private let state: Mutex<State>
    private let logger: Logger

    public init(logger: Logger = Logger(label: "wreaper.power")) {
        // Seed with the current display state so we start correctly even if
        // the daemon launches while the display is already asleep. This only
        // samples the main display: on a multi-display setup where a secondary
        // is asleep at launch we seed "visible". Known limitation — it
        // self-corrects on the next screensDidSleep notification.
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        state = Mutex(State(visible: !asleep))
        self.logger = logger
    }

    var activeTokenCount: Int {
        state.withLock { $0.tokens.count }
    }

    public nonisolated func isUserVisible() -> Bool {
        state.withLock { $0.visible }
    }

    public func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = state.withLock { s -> Bool in
                s.waiters[id] = continuation
                return s.visible
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.waiters[id] = nil }
            }
        }
    }

    public func start() async {
        let center = NSWorkspace.shared.notificationCenter
        // Register inside the lock so the freshly created (non-Sendable) tokens
        // are born in the state's region; their only captures (`center`, `self`)
        // are Sendable, so nothing task-isolated merges into the `inout sending`
        // parameter. Hoisting registration out (as a separate withLock) trips
        // Swift 6.2 region isolation: 'inout sending' cannot be task-isolated.
        let didStart = state.withLock { s -> Bool in
            guard s.tokens.isEmpty else { return false }
            let sleepToken = center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.transition(to: false)
            }
            let wakeToken = center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.transition(to: true)
            }
            s.tokens = [sleepToken, wakeToken]
            return true
        }
        guard didStart else { return }
        logger.notice("power state observer started video=\(isUserVisible())")
    }

    public func stop() async {
        let center = NSWorkspace.shared.notificationCenter
        let snapshot = state.withLock { s -> (tokens: [any NSObjectProtocol], waiters: [AsyncStream<Bool>.Continuation]) in
            let tokens = s.tokens
            s.tokens.removeAll()
            let waiters = Array(s.waiters.values)
            s.waiters.removeAll()
            return (tokens, waiters)
        }
        for token in snapshot.tokens {
            center.removeObserver(token)
        }
        for w in snapshot.waiters {
            w.finish()
        }
    }

    private func transition(to newValue: Bool) {
        let snapshot = state.withLock { s -> (changed: Bool, waiters: [AsyncStream<Bool>.Continuation]) in
            let changed = s.visible != newValue
            s.visible = newValue
            return (changed, Array(s.waiters.values))
        }
        if snapshot.changed {
            logger.notice("power state video=\(newValue ? "on" : "off")")
            for w in snapshot.waiters {
                w.yield(newValue)
            }
        }
    }
}
