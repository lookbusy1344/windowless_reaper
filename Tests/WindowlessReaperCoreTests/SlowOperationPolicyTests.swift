import Foundation
import Testing
@testable import WindowlessReaperCore

@Suite("SlowOperationPolicy", .timeLimit(.minutes(1)))
struct SlowOperationPolicyTests {
    @Test("warning triggers when elapsed exceeds threshold")
    func warningTriggersWhenSlow() {
        let policy = SlowOperationPolicy(
            thresholds: SlowOperationThresholds(
                tick: Swift.Duration.seconds(1),
                inspection: Swift.Duration.seconds(1),
                checkpoint: Swift.Duration.seconds(1),
                termination: Swift.Duration.seconds(1)
            )
        )
        let warning = policy.warning(
            phase: .inspection,
            elapsed: Swift.Duration.seconds(2),
            counts: SlowOperationCounts(appCount: 3, pidCount: 5, windowCount: 7)
        )

        #expect(warning != nil)
        if let warning {
            #expect(warning.phase == .inspection)
            #expect(warning.threshold == Swift.Duration.seconds(1))
        }
    }

    @Test("warning stays nil when elapsed is within threshold")
    func warningDoesNotTriggerWhenFast() {
        let policy = SlowOperationPolicy(
            thresholds: SlowOperationThresholds(
                tick: Swift.Duration.seconds(2),
                inspection: Swift.Duration.seconds(2),
                checkpoint: Swift.Duration.seconds(2),
                termination: Swift.Duration.seconds(2)
            )
        )

        let warning = policy.warning(
            phase: .tick,
            elapsed: Swift.Duration.seconds(2),
            counts: SlowOperationCounts(appCount: 1, pidCount: 1, windowCount: nil)
        )
        #expect(warning == nil)
    }

    @Test("render includes phase, elapsed, threshold, and counts")
    func renderIncludesCounts() {
        let policy = SlowOperationPolicy(
            thresholds: SlowOperationThresholds(
                tick: Swift.Duration.seconds(1),
                inspection: Swift.Duration.seconds(1),
                checkpoint: Swift.Duration.seconds(1),
                termination: Swift.Duration.seconds(1)
            )
        )
        let warning = SlowOperationWarning(
            phase: .termination,
            elapsed: Swift.Duration.seconds(3),
            threshold: Swift.Duration.seconds(1),
            counts: SlowOperationCounts(appCount: 2, pidCount: 4, windowCount: nil)
        )

        let rendered = policy.render(warning)
        #expect(rendered.contains("slow termination"))
        #expect(rendered.contains("elapsed=3s"))
        #expect(rendered.contains("threshold=1s"))
        #expect(rendered.contains("apps=2"))
        #expect(rendered.contains("pids=4"))
    }
}
