import Foundation

/// Lightweight counters for long-run triage. The snapshot is intentionally
/// small and bounded so it can be rendered in diagnostics without creating a
/// second source of churn.
public struct RuntimeHealthSnapshot: Sendable, Equatable, Codable {
    public let ticks: Int
    public let skippedAsleep: Int
    public let skippedNotVisible: Int
    public let skippedGrace: Int
    public let skippedImplicitWake: Int
    public let configUpdates: Int
    public let axUnknownInspections: Int
    public let checkpointSaveFailures: Int

    public init(
        ticks: Int,
        skippedAsleep: Int,
        skippedNotVisible: Int,
        skippedGrace: Int,
        skippedImplicitWake: Int,
        configUpdates: Int,
        axUnknownInspections: Int,
        checkpointSaveFailures: Int
    ) {
        self.ticks = ticks
        self.skippedAsleep = skippedAsleep
        self.skippedNotVisible = skippedNotVisible
        self.skippedGrace = skippedGrace
        self.skippedImplicitWake = skippedImplicitWake
        self.configUpdates = configUpdates
        self.axUnknownInspections = axUnknownInspections
        self.checkpointSaveFailures = checkpointSaveFailures
    }
}

struct RuntimeHealth {
    enum SkipReason {
        case asleep
        case notVisible
        case grace
        case implicitWake
    }

    var ticks = 0
    var skippedAsleep = 0
    var skippedNotVisible = 0
    var skippedGrace = 0
    var skippedImplicitWake = 0
    var configUpdates = 0
    var axUnknownInspections = 0
    var checkpointSaveFailures = 0

    mutating func noteTick() {
        ticks += 1
    }

    mutating func noteSkip(_ reason: SkipReason) {
        switch reason {
        case .asleep:
            skippedAsleep += 1
        case .notVisible:
            skippedNotVisible += 1
        case .grace:
            skippedGrace += 1
        case .implicitWake:
            skippedImplicitWake += 1
        }
    }

    mutating func noteConfigUpdate() {
        configUpdates += 1
    }

    mutating func noteAXUnknownInspection(count: Int) {
        axUnknownInspections += count
    }

    mutating func noteCheckpointSaveFailure() {
        checkpointSaveFailures += 1
    }

    var snapshot: RuntimeHealthSnapshot {
        RuntimeHealthSnapshot(
            ticks: ticks,
            skippedAsleep: skippedAsleep,
            skippedNotVisible: skippedNotVisible,
            skippedGrace: skippedGrace,
            skippedImplicitWake: skippedImplicitWake,
            configUpdates: configUpdates,
            axUnknownInspections: axUnknownInspections,
            checkpointSaveFailures: checkpointSaveFailures
        )
    }
}
