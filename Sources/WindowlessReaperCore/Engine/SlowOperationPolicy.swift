import Foundation

struct SlowOperationThresholds: Equatable {
    let tick: Swift.Duration
    let inspection: Swift.Duration
    let checkpoint: Swift.Duration
    let termination: Swift.Duration

    static let `default` = SlowOperationThresholds(
        tick: Swift.Duration.seconds(5),
        inspection: Swift.Duration.seconds(2),
        checkpoint: Swift.Duration.seconds(1),
        termination: Swift.Duration.seconds(1)
    )
}

struct SlowOperationCounts: Equatable {
    let appCount: Int
    let pidCount: Int
    let windowCount: Int?

    static let zero = SlowOperationCounts(appCount: 0, pidCount: 0, windowCount: nil)
}

enum SlowOperationPhase: String, Equatable {
    case tick
    case inspection
    case checkpoint
    case termination
}

struct SlowOperationWarning: Equatable {
    let phase: SlowOperationPhase
    let elapsed: Swift.Duration
    let threshold: Swift.Duration
    let counts: SlowOperationCounts
}

struct SlowOperationPolicy: Equatable {
    let thresholds: SlowOperationThresholds

    init(thresholds: SlowOperationThresholds = .default) {
        self.thresholds = thresholds
    }

    func warning(
        phase: SlowOperationPhase,
        elapsed: Swift.Duration,
        counts: SlowOperationCounts
    ) -> SlowOperationWarning? {
        let threshold = threshold(for: phase)
        guard elapsed > threshold else { return nil }
        return SlowOperationWarning(phase: phase, elapsed: elapsed, threshold: threshold, counts: counts)
    }

    func render(_ warning: SlowOperationWarning) -> String {
        var out = "slow \(warning.phase.rawValue) elapsed=\(Self.format(warning.elapsed)) threshold=\(Self.format(warning.threshold))"
        out += " apps=\(warning.counts.appCount)"
        out += " pids=\(warning.counts.pidCount)"
        if let windows = warning.counts.windowCount {
            out += " windows=\(windows)"
        }
        return out
    }

    private func threshold(for phase: SlowOperationPhase) -> Swift.Duration {
        switch phase {
        case .tick:
            thresholds.tick
        case .inspection:
            thresholds.inspection
        case .checkpoint:
            thresholds.checkpoint
        case .termination:
            thresholds.termination
        }
    }

    private static func format(_ duration: Swift.Duration) -> String {
        let totalSeconds = max(0, Int(duration.components.seconds))
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h\(m)m\(s)s" }
        if m > 0 { return "\(m)m\(s)s" }
        return "\(s)s"
    }
}
