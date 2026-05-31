import Foundation
import Testing
import WindowlessReaperCore

private func bid(_ s: String) -> BundleID {
    BundleID(s)
}

@Suite("default_timeout parsing", .timeLimit(.minutes(1)))
struct DefaultTimeoutParseTests {
    @Test("default_timeout in [settings] is parsed")
    func parsesDefaultTimeout() throws {
        let toml = """
        [settings]
        default_timeout = "3m"
        """
        let cfg = try ConfigLoader.load(toml: toml)
        #expect(cfg.settings.defaultTimeout?.seconds == 180)
    }

    @Test("omitted default_timeout leaves it nil")
    func defaultTimeoutNilByDefault() throws {
        let cfg = try ConfigLoader.load(toml: "")
        #expect(cfg.settings.defaultTimeout == nil)
    }

    @Test("timeout = \"default\" resolves to settings.default_timeout")
    func ruleUsesDefault() throws {
        let toml = """
        [settings]
        default_timeout = "3m"

        [apps."com.apple.mail"]
        timeout = "default"
        """
        let cfg = try ConfigLoader.load(toml: toml)
        let rule = try #require(cfg.rules[bid("com.apple.mail")])
        #expect(rule.timeout?.seconds == 180)
    }

    @Test("timeout = \"default\" without default_timeout is a hard error")
    func ruleDefaultWithoutSettingErrors() {
        let toml = """
        [apps."com.apple.mail"]
        timeout = "default"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("default_timeout itself accepts standard duration syntax")
    func defaultTimeoutDurationParsing() throws {
        let toml = """
        [settings]
        default_timeout = "45s"
        """
        let cfg = try ConfigLoader.load(toml: toml)
        #expect(cfg.settings.defaultTimeout?.seconds == 45)
    }

    @Test("invalid default_timeout string surfaces as ConfigError")
    func invalidDefaultTimeoutErrors() {
        let toml = """
        [settings]
        default_timeout = "nope"
        """
        #expect(throws: ConfigError.self) { try ConfigLoader.load(toml: toml) }
    }

    @Test("round-trip: default_timeout is emitted and re-parsed")
    func roundTripDefaultTimeout() throws {
        let original = Config(
            settings: Settings(
                pollInterval: Duration(seconds: 30),
                logLevel: "info",
                dryRun: false,
                defaultCooldown: .multiplier(5.0),
                defaultTimeout: Duration(seconds: 180)
            ),
            rules: [:]
        )
        let rendered = original.toTOML()
        #expect(rendered.contains("default_timeout"))
        let reparsed = try ConfigLoader.load(toml: rendered)
        #expect(reparsed.settings.defaultTimeout?.seconds == 180)
    }

    @Test("explicit per-app timeout is unaffected by default_timeout")
    func explicitTimeoutWins() throws {
        let toml = """
        [settings]
        default_timeout = "3m"

        [apps."com.apple.Safari"]
        timeout = "10m"
        """
        let cfg = try ConfigLoader.load(toml: toml)
        let rule = try #require(cfg.rules[bid("com.apple.Safari")])
        #expect(rule.timeout?.seconds == 600)
    }
}
