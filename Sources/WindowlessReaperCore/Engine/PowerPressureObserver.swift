import Foundation

/// Power source as reported by `IOPSGetProvidingPowerSourceType`. `.unknown`
/// covers boot-time races and the rare "no power sources" case (some Mac
/// minis, some virtualised environments) — treated as AC for policy
/// purposes since the more conservative choice is "don't back off".
public enum PowerSource: Sendable, Equatable {
    case ac
    case battery
    case unknown
}

/// A point-in-time read of the three runtime pressure signals defined in
/// power_man_best_practices.md §2.11. Equatable so an observer can
/// short-circuit duplicate transition emissions.
public struct PressureSnapshot: Sendable, Equatable {
    public let source: PowerSource
    public let lowPowerMode: Bool
    public let thermalState: ProcessInfo.ThermalState

    public init(source: PowerSource, lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        self.source = source
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }

    /// A "no pressure" snapshot — AC, LPM off, thermal nominal. Used as the
    /// default for engines that opt out of adaptive policy and as the seed
    /// for tests that don't care about pressure.
    public static let nominal = PressureSnapshot(source: .ac, lowPowerMode: false, thermalState: .nominal)
}

/// Observes runtime power pressure signals: power source (AC vs battery),
/// Low Power Mode, and `ProcessInfo.thermalState`.
///
/// Read from the engine's hot path via `snapshot()` (synchronous, no actor
/// hop — see the matching contract on `SystemPowerStateObserver`). The
/// engine polls `snapshot()` after each tick, so transitions are picked
/// up within at most one effective tick interval — no separate
/// transitions stream needed.
public protocol PowerPressureObserver: Sendable {
    nonisolated func snapshot() -> PressureSnapshot
    func start() async
    func stop() async
}

/// Trivial observer used as the engine default when adaptive pressure is
/// not wired by the caller. Returns the same snapshot forever. Lets
/// one-shot commands and most tests skip the IOPS poll on every tick.
struct StaticPressureObserver: PowerPressureObserver {
    private let value: PressureSnapshot

    init(_ value: PressureSnapshot) {
        self.value = value
    }

    nonisolated func snapshot() -> PressureSnapshot {
        value
    }

    func start() async {}
    func stop() async {}
}
