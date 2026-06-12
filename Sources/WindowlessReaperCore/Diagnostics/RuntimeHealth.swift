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
    public let axUnreadableWindows: Int
    public let checkpointSaveFailures: Int

    public init(
        ticks: Int,
        skippedAsleep: Int,
        skippedNotVisible: Int,
        skippedGrace: Int,
        skippedImplicitWake: Int,
        configUpdates: Int,
        axUnknownInspections: Int,
        axUnreadableWindows: Int = 0,
        checkpointSaveFailures: Int
    ) {
        self.ticks = ticks
        self.skippedAsleep = skippedAsleep
        self.skippedNotVisible = skippedNotVisible
        self.skippedGrace = skippedGrace
        self.skippedImplicitWake = skippedImplicitWake
        self.configUpdates = configUpdates
        self.axUnknownInspections = axUnknownInspections
        self.axUnreadableWindows = axUnreadableWindows
        self.checkpointSaveFailures = checkpointSaveFailures
    }

    /// Custom decoding keeps a sidecar written by an older build readable: the
    /// new key defaults to 0 rather than failing the whole snapshot decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticks = try c.decode(Int.self, forKey: .ticks)
        skippedAsleep = try c.decode(Int.self, forKey: .skippedAsleep)
        skippedNotVisible = try c.decode(Int.self, forKey: .skippedNotVisible)
        skippedGrace = try c.decode(Int.self, forKey: .skippedGrace)
        skippedImplicitWake = try c.decode(Int.self, forKey: .skippedImplicitWake)
        configUpdates = try c.decode(Int.self, forKey: .configUpdates)
        axUnknownInspections = try c.decode(Int.self, forKey: .axUnknownInspections)
        axUnreadableWindows = try c.decodeIfPresent(Int.self, forKey: .axUnreadableWindows) ?? 0
        checkpointSaveFailures = try c.decode(Int.self, forKey: .checkpointSaveFailures)
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
    var axUnreadableWindows = 0
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

    mutating func noteAXUnreadableWindows(count: Int) {
        axUnreadableWindows += count
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
            axUnreadableWindows: axUnreadableWindows,
            checkpointSaveFailures: checkpointSaveFailures
        )
    }
}
