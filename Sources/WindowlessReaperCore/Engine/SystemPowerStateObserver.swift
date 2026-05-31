/// Observes the system's user-visible power state. The engine queries this at
/// the top of every tick to skip work during dark wake and display sleep.
///
/// `isUserVisible()` is `nonisolated` and synchronous: it sits on the hot path
/// and must not require an actor hop to read a cached bool. Implementations
/// guard the bool with `Synchronization.Mutex`. Lifecycle methods stay `async`
/// to match the surrounding style.
public protocol SystemPowerStateObserver: Sendable {
    /// `true` when the system has display capability (user-visible wake).
    /// `false` during dark wake or display sleep.
    nonisolated func isUserVisible() -> Bool

    /// Emits the current visibility immediately, then on every transition.
    /// Each caller gets an independent stream; cancellation detaches the
    /// internal waiter — no leak on `Task` cancel.
    func transitions() -> AsyncStream<Bool>

    func start() async
    func stop() async
}
