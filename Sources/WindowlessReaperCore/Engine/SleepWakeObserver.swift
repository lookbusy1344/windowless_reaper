/// Observes macOS sleep/wake notifications. After a wake event, the engine
/// skips exactly one tick as a grace period — AX window lists can take a few
/// seconds to repopulate after wake, and without the skip we'd race app
/// restoration and mass-evict everything. The skip is independent of the
/// clock pause and is justified by AX latency, not time accounting.
public protocol SleepWakeObserver: Sendable {
    /// Returns `true` exactly once after each wake event, then `false` until
    /// the next wake. The engine calls this at the top of every tick and
    /// short-circuits the tick when the result is `true`.
    func consumeGraceTick() async -> Bool

    /// Level-triggered sleep flag: `true` for the entire interval between
    /// `willSleep` and `willPowerOn` (or NSWorkspace `willSleepNotification`
    /// / `didWakeNotification`). Belt-and-braces with the screen-sleep
    /// power-visibility gate; either firing must suppress the tick. Unlike
    /// `consumeGraceTick`, this is read-only and idempotent.
    func isAsleep() async -> Bool

    /// Awake/asleep transitions. Yields `true` for awake, `false` for asleep.
    /// Emits the current state immediately on subscription, then again on
    /// every change. Each subscriber gets an independent stream; cancellation
    /// detaches the waiter — no leak on `Task` cancel.
    ///
    /// Used by the engine to tear down the tick stream on `willSleep` so the
    /// `DispatchSourceTimer` doesn't fire during dark-wake maintenance
    /// windows. The level-triggered `isAsleep()` check at tick start remains
    /// as a defence-in-depth backstop for the race where a tick is already
    /// in flight when the transition arrives.
    func transitions() -> AsyncStream<Bool>

    func start() async
    func stop() async
}
