import Foundation
import Synchronization
import WindowlessReaperCore

// MARK: - Clock

/// Virtual clock for time-sensitive tests. Advances only when `advance(by:)`
/// is called — wall-clock time is irrelevant. Proves that elapsed-time
/// semantics in the engine are decoupled from real time.
public final class TestClock: Clock, @unchecked Sendable {
    private struct State {
        var currentInstant: SuspendingClock.Instant
        var currentContinuous: ContinuousClock.Instant
        var continuations: [UUID: AsyncStream<SuspendingClock.Instant>.Continuation] = [:]
        var terminationCount = 0
    }

    private final class Storage: @unchecked Sendable {
        let state = Mutex(State(currentInstant: SuspendingClock.now, currentContinuous: ContinuousClock.now))
    }

    private let storage = Storage()

    public init() {}

    public func now() async -> SuspendingClock.Instant {
        storage.state.withLock { $0.currentInstant }
    }

    public func continuousNow() async -> ContinuousClock.Instant {
        storage.state.withLock { $0.currentContinuous }
    }

    /// Advance both suspending and continuous clocks — models normal wall-time progress.
    public func advance(by duration: Duration) async {
        let continuations: [AsyncStream<SuspendingClock.Instant>.Continuation] = storage.state.withLock { state in
            state.currentInstant = state.currentInstant.advanced(by: .seconds(duration.seconds))
            state.currentContinuous = state.currentContinuous.advanced(by: .seconds(duration.seconds))
            return Array(state.continuations.values)
        }
        let currentInstant = await now()
        for continuation in continuations {
            continuation.yield(currentInstant)
        }
    }

    /// Advance only the continuous clock — models system sleep, where wall
    /// time elapses but the suspending clock pauses. Used to exercise the
    /// engine's implicit-wake (clock-drift) detection.
    public func advanceContinuousOnly(by duration: Duration) async {
        storage.state.withLock {
            $0.currentContinuous = $0.currentContinuous.advanced(by: .seconds(duration.seconds))
        }
    }

    public func tickStream(interval _: Duration) -> AsyncStream<SuspendingClock.Instant> {
        let storage = storage
        return AsyncStream { continuation in
            let id = UUID()
            storage.state.withLock { state in
                state.continuations[id] = continuation
            }
            continuation.onTermination = { [storage] _ in
                storage.state.withLock { state in
                    state.terminationCount += 1
                    state.continuations[id] = nil
                }
            }
        }
    }

    public var subscriberCount: Int {
        get async {
            storage.state.withLock { $0.continuations.count }
        }
    }

    public var terminationCount: Int {
        get async {
            storage.state.withLock { $0.terminationCount }
        }
    }
}

// MARK: - AppEnumerator

public actor FakeAppEnumerator: AppEnumerator {
    private var apps: [RunningApp]
    public private(set) var callCount: Int = 0

    public init(apps: [RunningApp] = []) {
        self.apps = apps
    }

    public func setApps(_ apps: [RunningApp]) {
        self.apps = apps
    }

    public func enumerate() -> [RunningApp] {
        callCount += 1
        return apps
    }
}

// MARK: - WindowInspector

public actor FakeWindowInspector: WindowInspector {
    private var states: [pid_t: WindowState]
    private var defaultState: WindowState
    public private(set) var requestedPIDs: [pid_t] = []

    public init(states: [pid_t: WindowState] = [:], default defaultState: WindowState = .none) {
        self.states = states
        self.defaultState = defaultState
    }

    public func setState(_ state: WindowState, for pid: pid_t) {
        states[pid] = state
    }

    public func windowState(for pid: pid_t) -> WindowState {
        requestedPIDs.append(pid)
        return states[pid] ?? defaultState
    }
}

// MARK: - Terminator

public actor FakeTerminator: Terminator {
    public private(set) var terminatedPIDs: [pid_t] = []
    private var vetoes: Set<pid_t> = []

    public init() {}

    public func vetoTermination(for pid: pid_t) {
        vetoes.insert(pid)
    }

    public func terminate(pid: pid_t) -> Bool {
        if vetoes.contains(pid) { return false }
        terminatedPIDs.append(pid)
        return true
    }
}

// MARK: - SystemPowerStateObserver

public final class FakePowerState: SystemPowerStateObserver {
    private struct State {
        var visible: Bool
        var waiters: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let _state: Mutex<State>

    public init(initiallyVisible: Bool = true) {
        _state = Mutex(State(visible: initiallyVisible))
    }

    public func setVisible(_ v: Bool) {
        let snapshot = _state.withLock { s -> (changed: Bool, waiters: [AsyncStream<Bool>.Continuation]) in
            let changed = s.visible != v
            s.visible = v
            return (changed, Array(s.waiters.values))
        }
        if snapshot.changed {
            for w in snapshot.waiters {
                w.yield(v)
            }
        }
    }

    public nonisolated func isUserVisible() -> Bool {
        _state.withLock { $0.visible }
    }

    public func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = _state.withLock { s -> Bool in
                s.waiters[id] = continuation
                return s.visible
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?._state.withLock { $0.waiters[id] = nil }
            }
        }
    }

    /// Test-only: number of active transition subscribers.
    public var waiterCount: Int {
        _state.withLock { $0.waiters.count }
    }

    public func start() async {}

    public func stop() async {
        let waiters = _state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            let copy = Array(s.waiters.values)
            s.waiters.removeAll()
            return copy
        }
        for w in waiters {
            w.finish()
        }
    }
}

// MARK: - PowerPressureObserver

public final class FakePowerPressure: PowerPressureObserver {
    private let current: Mutex<PressureSnapshot>

    public init(_ initial: PressureSnapshot = .nominal) {
        current = Mutex(initial)
    }

    public nonisolated func snapshot() -> PressureSnapshot {
        current.withLock { $0 }
    }

    public func set(_ snapshot: PressureSnapshot) {
        current.withLock { $0 = snapshot }
    }

    public func start() async {}
    public func stop() async {}
}

// MARK: - SleepWakeObserver

public final class FakeSleepWake: SleepWakeObserver {
    private struct State {
        var graceTickPending: Bool = false
        var asleep: Bool = false
        var started: Bool = false
        var stopped: Bool = false
        var waiters: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State> = Mutex(State())

    public init() {}

    public var started: Bool {
        get async { state.withLock { $0.started } }
    }

    public var stopped: Bool {
        get async { state.withLock { $0.stopped } }
    }

    public func start() async {
        state.withLock { $0.started = true }
    }

    public func stop() async {
        let drained = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            s.stopped = true
            let copy = Array(s.waiters.values)
            s.waiters.removeAll()
            return copy
        }
        for w in drained {
            w.finish()
        }
    }

    public func simulateSleep() async {
        let waiters = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            let changed = !s.asleep
            s.asleep = true
            return changed ? Array(s.waiters.values) : []
        }
        for w in waiters {
            w.yield(false)
        }
    }

    public func simulateWake() async {
        let waiters = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            let changed = s.asleep
            s.asleep = false
            s.graceTickPending = true
            return changed ? Array(s.waiters.values) : []
        }
        for w in waiters {
            w.yield(true)
        }
    }

    public func consumeGraceTick() async -> Bool {
        state.withLock { s in
            let pending = s.graceTickPending
            s.graceTickPending = false
            return pending
        }
    }

    public func isAsleep() async -> Bool {
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

    /// Test-only: number of active transition subscribers.
    public var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}

/// Test-only `SleepWakeObserver` that does **not** yield the current state
/// when a subscriber attaches. Tests drive emissions explicitly via `emit(_:)`,
/// which makes the ordering of child events deterministic — required for
/// reproducing races between observers that report sleep state at different
/// times (e.g. IOKit vs NSWorkspace).
public final class ManualSleepWake: SleepWakeObserver {
    private struct State {
        var asleep: Bool
        var waiters: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State>

    public init(asleep: Bool) {
        state = Mutex(State(asleep: asleep))
    }

    public func start() async {}
    public func stop() async {
        let drained = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            let copy = Array(s.waiters.values)
            s.waiters.removeAll()
            return copy
        }
        for w in drained {
            w.finish()
        }
    }

    public func consumeGraceTick() async -> Bool {
        false
    }

    public func isAsleep() async -> Bool {
        state.withLock { $0.asleep }
    }

    /// Push a value to every active subscriber and update the recorded state.
    public func emit(awake: Bool) async {
        let waiters = state.withLock { s -> [AsyncStream<Bool>.Continuation] in
            s.asleep = !awake
            return Array(s.waiters.values)
        }
        for w in waiters {
            w.yield(awake)
        }
    }

    public func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { $0.waiters[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.waiters[id] = nil }
            }
        }
    }

    /// Test-only: number of active transition subscribers.
    public var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}
