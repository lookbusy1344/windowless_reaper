import Foundation
import Testing
@testable import WindowlessReaperCore

// Intentional white-box coverage: this suite exercises the same internal
// `StateTracker` state machine as `M4StateTrackerTests`, but with the `none`
// timeout parsing edge cases that are easier to assert from inside the module.

private func bid(_ s: String) -> BundleID {
    BundleID(s)
}

@Suite("timeout = \"none\" parsing", .timeLimit(.minutes(1)))
struct NoneTimeoutParseTests {
    @Test("timeout = \"none\" parses to a rule with nil timeout")
    func parsesNoneTimeout() throws {
        let toml = """
        [apps."com.apple.mail"]
        timeout = "none"
        """
        let cfg = try ConfigLoader.load(toml: toml)
        let rule = try #require(cfg.rules[bid("com.apple.mail")])
        #expect(rule.timeout == nil)
        #expect(rule.cooldown == nil)
    }

    @Test("cooldown = \"none\" parses identically to omitted cooldown")
    func parsesNoneCooldown() throws {
        let toml = """
        [apps."com.apple.mail"]
        timeout  = "10m"
        cooldown = "none"
        """
        let cfg = try ConfigLoader.load(toml: toml)
        let rule = try #require(cfg.rules[bid("com.apple.mail")])
        #expect(rule.timeout?.seconds == 600)
        #expect(rule.cooldown == nil)
    }

    @Test("missing timeout is still a hard error — \"none\" must be explicit")
    func missingTimeoutStillError() {
        let toml = """
        [apps."com.apple.mail"]
        cooldown = "10m"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("round-trip: rule with nil timeout renders as \"none\" and re-parses")
    func roundTripNoneRule() throws {
        let original = Config(
            settings: Settings.defaults,
            rules: [bid("com.apple.Notes"): Rule(timeout: nil)]
        )
        let rendered = original.toTOML()
        #expect(rendered.contains("timeout = 'none'"))
        let reparsed = try ConfigLoader.load(toml: rendered)
        let rule = try #require(reparsed.rules[bid("com.apple.Notes")])
        #expect(rule.timeout == nil)
    }
}

@Suite("timeout = \"none\" engine behaviour", .timeLimit(.minutes(1)))
struct NoneTimeoutEngineTests {
    private static let safari = bid("com.apple.Safari")

    private static func config(_ rules: [BundleID: Rule]) -> Config {
        Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0)
            ),
            rules: rules
        )
    }

    private static func windowless(_ id: BundleID, pid: pid_t = 100) -> AppSnapshot {
        AppSnapshot(bundleID: id, windowStates: [pid: .none])
    }

    @Test("rule with nil timeout produces .ignore, never .track or .evict — even far past any plausible timeout")
    func neverEvictsNoneRule() {
        let cfg = Self.config([Self.safari: Rule(timeout: nil)])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now

        for offset in [0, 60, 3600, 86400] {
            let decisions = tracker.tick(
                now: t0.advanced(by: .seconds(offset)),
                snapshots: [Self.windowless(Self.safari)],
                config: cfg
            )
            #expect(decisions.count == 1)
            if case .ignore(let id) = decisions[0] {
                #expect(id == Self.safari)
            } else {
                Issue.record("expected .ignore at offset \(offset)s, got \(decisions[0])")
            }
        }
        // Critically: no persistent state retained for a nil-timeout bundle.
        #expect(tracker.states.isEmpty)
    }

    @Test("flipping a rule from active to none clears any tracked state")
    func flipToNoneClearsState() {
        let active = Self.config([Self.safari: Rule(timeout: Duration(seconds: 60))])
        var tracker = StateTracker()
        let t0 = SuspendingClock.now

        // First tick: starts tracking with an active rule.
        _ = tracker.tick(now: t0, snapshots: [Self.windowless(Self.safari)], config: active)
        #expect(!tracker.states.isEmpty)

        // User edits config: timeout = "none". State must drop, decision must be ignore.
        let none = Self.config([Self.safari: Rule(timeout: nil)])
        let decisions = tracker.tick(
            now: t0.advanced(by: .seconds(30)),
            snapshots: [Self.windowless(Self.safari)],
            config: none
        )
        #expect(tracker.states.isEmpty)
        if case .ignore = decisions.first {} else {
            Issue.record("expected .ignore after flipping to none, got \(String(describing: decisions.first))")
        }
    }
}
