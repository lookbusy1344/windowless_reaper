import Foundation
import IOKit.ps
import Logging
import Synchronization

/// Production `PowerPressureObserver` backed by:
///
/// - `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType` for AC
///   vs battery. Polled fresh on every `snapshot()` (cheap, microseconds)
///   rather than wiring `IOPSNotificationCreateRunLoopSource` — we have no
///   CFRunLoop pump, and a per-tick poll converges within one tick of any
///   transition.
/// - `ProcessInfo.processInfo.isLowPowerModeEnabled` plus
///   `NSProcessInfoPowerStateDidChange` for event-driven LPM diagnostics.
/// - `ProcessInfo.processInfo.thermalState` plus
///   `ProcessInfo.thermalStateDidChangeNotification` for event-driven
///   thermal diagnostics.
///
/// The NotificationCenter subscriptions log transitions but don't drive
/// the engine — the engine polls `snapshot()` after every tick, so
/// adaptive-policy reaction is bounded by one effective interval.
public final class SystemPowerPressure: PowerPressureObserver {
    private struct State {
        var last: PressureSnapshot
        var tokens: [any NSObjectProtocol] = []
    }

    private let state: Mutex<State>
    private let logger: Logger

    public init(logger: Logger = Logger(label: "wreaper.power-pressure")) {
        let seed = PressureSnapshot(
            source: Self.currentPowerSource(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
        state = Mutex(State(last: seed))
        self.logger = logger
    }

    var activeTokenCount: Int {
        state.withLock { $0.tokens.count }
    }

    public nonisolated func snapshot() -> PressureSnapshot {
        PressureSnapshot(
            source: Self.currentPowerSource(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    public func start() async {
        let center = NotificationCenter.default
        // Register inside the lock so the freshly created (non-Sendable) tokens
        // are born in the state's region; their only captures (`center`, `self`)
        // are Sendable, so nothing task-isolated merges into the `inout sending`
        // parameter. Hoisting registration out (as a separate withLock) trips
        // Swift 6.2 region isolation: 'inout sending' cannot be task-isolated.
        let didStart = state.withLock { s -> Bool in
            guard s.tokens.isEmpty else { return false }
            let lpmToken = center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.logTransition(reason: "lpm")
            }
            let thermalToken = center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.logTransition(reason: "thermal")
            }
            s.tokens = [lpmToken, thermalToken]
            return true
        }
        guard didStart else { return }
        logger.notice("power-pressure observer started \(Self.describe(snapshot()))")
    }

    public func stop() async {
        let center = NotificationCenter.default
        let tokens = state.withLock { s -> [any NSObjectProtocol] in
            let captured = s.tokens
            s.tokens.removeAll()
            return captured
        }
        for token in tokens {
            center.removeObserver(token)
        }
    }

    private func logTransition(reason: String) {
        let fresh = snapshot()
        let changed = state.withLock { s -> Bool in
            let c = s.last != fresh
            if c { s.last = fresh }
            return c
        }
        guard changed else { return }
        logger.notice("power-pressure changed reason=\(reason) \(Self.describe(fresh))")
    }

    private static func currentPowerSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        guard let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return .unknown
        }
        switch providing {
        case kIOPSACPowerValue: return .ac
        case kIOPSBatteryPowerValue: return .battery
        default: return .unknown
        }
    }

    private static func describe(_ s: PressureSnapshot) -> String {
        "source=\(s.source) lpm=\(s.lowPowerMode) thermal=\(thermalName(s.thermalState))"
    }

    private static func thermalName(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
