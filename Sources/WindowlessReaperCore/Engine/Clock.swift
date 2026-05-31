import Dispatch
import Foundation

/// Time seam for the engine. All elapsed-time decisions read `now()`, which is
/// backed by `SuspendingClock` in production so system sleep does not advance
/// timers (a laptop asleep for 4h must not trigger mass eviction on wake).
///
/// `continuousNow()` returns a `ContinuousClock` reading, which *does* advance
/// during system sleep. The engine compares the two between ticks to detect
/// suspensions that macOS failed to broadcast via NSWorkspace notifications
/// (notably dark wake on AC power).
///
/// Tick scheduling uses `DispatchSourceTimer` (mach absolute time, pauses
/// across system sleep) with 10% leeway so the kernel can coalesce our
/// wake with other timers. The streamed instants remain
/// `SuspendingClock.Instant` so elapsed-time math stays sleep-aware.
public protocol Clock: Sendable {
    func now() async -> SuspendingClock.Instant
    func continuousNow() async -> ContinuousClock.Instant
    func tickStream(interval: Duration) -> AsyncStream<SuspendingClock.Instant>
}

public struct SystemClock: Clock {
    public init() {}

    public func now() async -> SuspendingClock.Instant {
        SuspendingClock.now
    }

    public func continuousNow() async -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    /// Backed by a `DispatchSourceTimer` carrying 10% leeway so the kernel can
    /// coalesce our wake with other timers (Energy Efficiency Guide for Mac
    /// Apps recommendation; see power_man_best_practices.md §§2.2, 4.7). A
    /// minimum 1 s leeway floor keeps degenerate tiny intervals (only reached
    /// by unit tests; config validation enforces a 10 s minimum) sensible.
    /// `qos: .utility` matches §2.21 — periodic, yields to user work, gets
    /// some App Nap protection.
    public func tickStream(interval: Duration) -> AsyncStream<SuspendingClock.Instant> {
        let seconds = interval.seconds
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "wreaper.tick", qos: .utility)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let leewayMs = max(1000, seconds * 100)
            timer.schedule(
                deadline: .now() + .seconds(seconds),
                repeating: .seconds(seconds),
                leeway: .milliseconds(leewayMs)
            )
            timer.setEventHandler {
                continuation.yield(SuspendingClock.now)
            }
            continuation.onTermination = { _ in timer.cancel() }
            timer.resume()
        }
    }
}
