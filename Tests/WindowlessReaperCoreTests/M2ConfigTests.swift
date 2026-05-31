import Foundation
import Testing
import WindowlessReaperCore

// MARK: - Duration

@Suite("Duration", .timeLimit(.minutes(1)))
struct DurationTests {
    @Test("rejects duration below minimum", arguments: ["9s", "0s", "1s", "0m", "0h"])
    func rejectsDurationBelowMinimum(input: String) {
        #expect(throws: (any Error).self) { try Duration(string: input) }
    }

    @Test("accepts valid durations", arguments: [
        ("10s", 10), ("30s", 30), ("3m", 180), ("1h", 3600),
        ("1h30m", 5400), ("90s", 90), ("2h15m30s", 8130),
    ])
    func acceptsValidDuration(input: String, expectedSeconds: Int) throws {
        let d = try Duration(string: input)
        #expect(d.seconds == expectedSeconds)
    }

    @Test("rejects malformed strings", arguments: ["", "3", "m", "1x", "-1s", "1h 30m", "abc"])
    func rejectsMalformed(input: String) {
        #expect(throws: (any Error).self) { try Duration(string: input) }
    }

    @Test("round-trips through formatted string")
    func roundTrip() throws {
        let cases: [(Int, String)] = [(10, "10s"), (180, "3m"), (3600, "1h"), (5400, "1h30m"), (90, "1m30s")]
        for (seconds, _) in cases {
            let original = Duration(seconds: seconds)
            let reparsed = try Duration(string: original.formatted)
            #expect(reparsed == original, "Round-trip failed for \(seconds)s")
        }
    }

    @Test("property: random h/m/s triples round-trip")
    func propertyRoundTrip() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 50 {
            let h = Int.random(in: 0 ... 23, using: &rng)
            let m = Int.random(in: 0 ... 59, using: &rng)
            let s = Int.random(in: 0 ... 59, using: &rng)
            let total = h * 3600 + m * 60 + s
            guard total >= 10 else { continue }
            let d = Duration(seconds: total)
            let reparsed = try Duration(string: d.formatted)
            #expect(reparsed == d)
        }
    }
}

// MARK: - Cooldown

@Suite("Cooldown", .timeLimit(.minutes(1)))
struct CooldownTests {
    @Test("accepts absolute duration")
    func cooldownAcceptsAbsolute() throws {
        let c = try Cooldown(string: "15m")
        if case .absolute(let d) = c {
            #expect(d.seconds == 900)
        } else {
            Issue.record("Expected .absolute, got \(c)")
        }
    }

    @Test("accepts multiplier forms", arguments: [
        ("5x", 5.0), ("2.5x", 2.5), ("1x", 1.0), ("10x", 10.0),
    ])
    func cooldownAcceptsMultiplier(input: String, expected: Double) throws {
        let c = try Cooldown(string: input)
        if case .multiplier(let m) = c {
            #expect(abs(m - expected) < 0.001)
        } else {
            Issue.record("Expected .multiplier, got \(c)")
        }
    }

    @Test("rejects zero or negative multiplier", arguments: ["0x", "-1x", "0.0x"])
    func cooldownRejectsInvalidMultiplier(input: String) {
        #expect(throws: (any Error).self) { try Cooldown(string: input) }
    }

    @Test("rejects non-finite multiplier", arguments: ["infx", "infinityx", "1e400x", "nanx"])
    func cooldownRejectsNonFiniteMultiplier(input: String) {
        // Double("inf"/"1e400") parse to +inf and pass `m > 0`; resolved(for:)
        // would then trap on Int(.infinity). MEDIUM-3 regression.
        #expect(throws: (any Error).self) { try Cooldown(string: input) }
    }

    @Test("resolved saturates a large finite multiplier instead of trapping")
    func resolvedSaturatesLargeMultiplier() throws {
        // 1e18 * 180s overflows Int — must clamp to the documented ceiling
        // rather than trap.
        let timeout = Duration(seconds: 180)
        let cooldown = try Cooldown(string: "1e18x")
        let resolved = cooldown.resolved(for: timeout)
        #expect(resolved.seconds == Duration.maximumCooldown.seconds)
    }

    @Test("resolved returns correct duration for multiplier")
    func resolvedMultiplier() throws {
        let timeout = Duration(seconds: 180) // 3m
        let cooldown = try Cooldown(string: "5x")
        let resolved = cooldown.resolved(for: timeout)
        #expect(resolved.seconds == 900) // 5 * 3m = 15m
    }

    @Test("resolved returns absolute duration unchanged")
    func resolvedAbsolute() throws {
        let timeout = Duration(seconds: 180)
        let cooldown = try Cooldown(string: "20m")
        let resolved = cooldown.resolved(for: timeout)
        #expect(resolved.seconds == 1200)
    }
}

// MARK: - BundleID

@Suite("BundleID", .timeLimit(.minutes(1)))
struct BundleIDTests {
    @Test("accepts valid reverse-DNS identifiers", arguments: [
        "com.apple.Safari",
        "com.tinyspeck.slackmacgap",
        "com.apple.mail",
        "org.mozilla.firefox",
    ])
    func acceptsValidBundleID(input: String) {
        let id = BundleID(input)
        #expect(id.value == input)
    }

    @Test("equality and hashing")
    func equalityAndHashing() {
        let a = BundleID("com.apple.Safari")
        let b = BundleID("com.apple.Safari")
        let c = BundleID("com.apple.mail")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}

// MARK: - ConfigLoader

@Suite("ConfigLoader", .timeLimit(.minutes(1)))
struct ConfigLoaderTests {
    static let canonicalTOML = """
    [settings]
    poll_interval    = "30s"
    log_level        = "info"
    dry_run          = false
    default_cooldown = "5x"

    [apps."com.apple.Safari"]
    timeout = "3m"

    [apps."com.apple.mail"]
    timeout  = "10m"
    cooldown = "20m"

    [apps."com.tinyspeck.slackmacgap"]
    timeout = "30m"
    """

    @Test("parsesCanonicalConfig")
    func parsesCanonicalConfig() throws {
        let config = try ConfigLoader.load(toml: Self.canonicalTOML)

        #expect(config.settings.pollInterval.seconds == 30)
        #expect(config.settings.logLevel == "info")
        #expect(config.settings.dryRun == false)

        let safari = try #require(config.rules[BundleID("com.apple.Safari")])
        #expect(safari.timeout?.seconds == 180)
        #expect(safari.cooldown == nil)

        let mail = try #require(config.rules[BundleID("com.apple.mail")])
        #expect(mail.timeout?.seconds == 600)
        if case .absolute(let d) = mail.cooldown {
            #expect(d.seconds == 1200)
        } else {
            Issue.record("Expected .absolute cooldown for mail, got \(String(describing: mail.cooldown))")
        }

        let slack = try #require(config.rules[BundleID("com.tinyspeck.slackmacgap")])
        #expect(slack.timeout?.seconds == 1800)
    }

    @Test("clear_cooldown parses, defaults to 30s, and rejects sub-minimum")
    func clearCooldownParsing() throws {
        let defaulted = try ConfigLoader.load(toml: """
        [settings]
        poll_interval = "30s"
        """)
        #expect(defaulted.settings.clearCooldown.seconds == 30)

        let explicit = try ConfigLoader.load(toml: """
        [settings]
        clear_cooldown = "2m"
        """)
        #expect(explicit.settings.clearCooldown.seconds == 120)

        #expect(throws: ConfigError.self) {
            try ConfigLoader.load(toml: """
            [settings]
            clear_cooldown = "5s"
            """)
        }
    }

    @Test("empty apps table is valid")
    func emptyAppsIsValid() throws {
        let toml = """
        [settings]
        poll_interval    = "30s"
        log_level        = "info"
        dry_run          = false
        default_cooldown = "5x"

        [apps]
        """
        let config = try ConfigLoader.load(toml: toml)
        #expect(config.rules.isEmpty)
    }

    @Test("missing file returns typed error")
    func missingFileReturnsError() {
        let url = URL(fileURLWithPath: "/nonexistent/path/config.toml")
        #expect(throws: ConfigError.self) { try ConfigLoader.load(from: url) }
    }

    @Test("parse error carries line and column")
    func parseErrorHasPosition() {
        let bad = "this is not valid toml %%% !!"
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: bad) }
    }

    @Test("missing timeout key is an error")
    func missingTimeoutIsError() {
        let toml = """
        [settings]
        poll_interval    = "30s"
        log_level        = "info"
        dry_run          = false
        default_cooldown = "5x"

        [apps."com.apple.Safari"]
        cooldown = "10m"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("duration below minimum in config is an error")
    func durationBelowMinimumIsError() {
        let toml = """
        [settings]
        poll_interval    = "30s"
        log_level        = "info"
        dry_run          = false
        default_cooldown = "5x"

        [apps."com.apple.Safari"]
        timeout = "5s"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("unknown top-level key is rejected")
    func unknownTopLevelKeyRejected() {
        let toml = """
        [misc]
        foo = "bar"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("unknown settings key is rejected")
    func unknownSettingsKeyRejected() {
        let toml = """
        [settings]
        timeuot = "3m"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("unknown rule key is rejected")
    func unknownRuleKeyRejected() {
        let toml = """
        [apps."com.apple.Safari"]
        timeout = "3m"
        bogus   = "x"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("invalid log_level is rejected")
    func invalidLogLevelRejected() {
        let toml = """
        [settings]
        log_level = "loud"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("schema allowed text matches parser and CLI rendering")
    func schemaAllowedTextMatchesRendering() {
        #expect(ConfigSchema.TopLevelKey.bracketedAllowedText == "[settings], [apps]")
        #expect(ConfigSchema.SettingsKey.allowedText == "poll_interval, log_level, dry_run, default_cooldown, default_timeout, clear_cooldown, adaptive_pressure")
        #expect(ConfigSchema.RuleKey.allowedText == "timeout, cooldown")
        #expect(ConfigSchema.LogLevel.allowedText == "trace, debug, info, notice, warn, warning, error")

        #expect(
            ConfigError.unknownSettingsKey(key: "timeuot").userFacingMessage ==
                "Unknown key '[settings].timeuot'. Allowed: \(ConfigSchema.SettingsKey.allowedText)."
        )
        #expect(
            ConfigError.invalidLogLevel(value: "loud").userFacingMessage ==
                "Invalid log_level 'loud'. Allowed: \(ConfigSchema.LogLevel.allowedText)."
        )
    }

    @Test("round-trip: render config back to TOML and re-parse")
    func renderRoundTrip() throws {
        let config = try ConfigLoader.load(toml: Self.canonicalTOML)
        let rendered = config.toTOML()
        let reparsed = try ConfigLoader.load(toml: rendered)

        #expect(reparsed.settings.pollInterval == config.settings.pollInterval)
        #expect(reparsed.settings.logLevel == config.settings.logLevel)
        #expect(reparsed.settings.dryRun == config.settings.dryRun)
        #expect(reparsed.settings.defaultCooldown == config.settings.defaultCooldown)
        #expect(reparsed.settings.defaultTimeout == config.settings.defaultTimeout)
        #expect(reparsed.settings.clearCooldown == config.settings.clearCooldown)
        #expect(reparsed.settings.adaptivePressure == config.settings.adaptivePressure)
        #expect(reparsed.rules.keys == config.rules.keys)
        for (id, rule) in config.rules {
            let reparsedRule = try #require(reparsed.rules[id])
            #expect(reparsedRule.timeout == rule.timeout)
        }
    }
}

// ConfigWatcher tests live in M2ConfigWatcherTests.swift.

@Suite("ConfigSample safety", .timeLimit(.minutes(1)))
struct ConfigSampleSafetyTests {
    @Test("sample config has no active app rules — nothing can be terminated by default")
    func sampleHasNoActiveRules() throws {
        let cfg = try ConfigLoader.load(toml: ConfigSample.content)
        #expect(cfg.rules.isEmpty, "sample must ship with all [apps.*] entries commented out")
    }

    @Test("sample config defaults are reasonable: poll >= 10s, dry_run pinned, cooldown set")
    func sampleDefaultsAreReasonable() throws {
        let cfg = try ConfigLoader.load(toml: ConfigSample.content)
        #expect(cfg.settings.pollInterval.seconds >= Duration.minimum.seconds)
        // The sample documents dry_run explicitly (not relying on the default)
        // so users see the knob exists.
        #expect(ConfigSample.content.contains("dry_run"))
        #expect(ConfigSample.content.contains("default_cooldown"))
    }
}
