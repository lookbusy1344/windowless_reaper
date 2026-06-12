import Foundation

/// Self-contained text block intended for pasting into a bug report. No PII
/// beyond bundle IDs the user already listed in their config. Sections are
/// fixed and headers are stable so downstream parsers (or graders) can rely
/// on the format.
public struct DiagnoseReport: Sendable {
    public let version: String
    public let axTrusted: Bool
    public let configPath: String
    public let config: Config?
    public let configError: String?
    public let decisions: [Decision]
    public let pid: pid_t
    public let effectiveLogLevel: String?
    public let effectiveDryRun: Bool?
    public let launchAgentPlistPath: String?
    public let launchAgentInstalled: Bool
    public let logTailPath: String?
    public let health: RuntimeHealthSnapshot?

    public init(
        version: String,
        axTrusted: Bool,
        configPath: String,
        config: Config?,
        configError: String? = nil,
        decisions: [Decision],
        pid: pid_t,
        effectiveLogLevel: String? = nil,
        effectiveDryRun: Bool? = nil,
        launchAgentPlistPath: String? = nil,
        launchAgentInstalled: Bool = false,
        logTailPath: String? = nil,
        health: RuntimeHealthSnapshot? = nil
    ) {
        self.version = version
        self.axTrusted = axTrusted
        self.configPath = configPath
        self.config = config
        self.configError = configError
        self.decisions = decisions
        self.pid = pid
        self.effectiveLogLevel = effectiveLogLevel
        self.effectiveDryRun = effectiveDryRun
        self.launchAgentPlistPath = launchAgentPlistPath
        self.launchAgentInstalled = launchAgentInstalled
        self.logTailPath = logTailPath
        self.health = health
    }

    public func render() -> String {
        var out = ""
        out += "[version]\n"
        out += "version: \(version)\n"
        out += "pid: \(pid)\n\n"

        out += "[accessibility]\n"
        out += "accessibility: \(axTrusted ? "granted" : "not granted")\n\n"

        out += "[config]\n"
        out += "config: \(configPath)\n"
        if let config {
            out += "poll_interval: \(config.settings.pollInterval)\n"
            out += "log_level: \(config.settings.logLevel)\n"
            out += "dry_run: \(config.settings.dryRun)\n"
            out += "rules: \(config.rules.count)\n"
            for bundleID in config.rules.keys.sorted(by: { $0.value < $1.value }) {
                guard let rule = config.rules[bundleID] else { continue }
                let timeoutText = rule.timeout.map(String.init(describing:)) ?? "none"
                out += "  \(bundleID.value) timeout=\(timeoutText)"
                if let cooldown = rule.cooldown {
                    out += " cooldown=\(cooldown)"
                }
                out += "\n"
            }
        } else if let err = configError {
            out += "config: (failed to load) \(err)\n"
        } else {
            out += "config: (none loaded)\n"
        }
        out += "\n"

        out += "[effective]\n"
        out += "log_level: \(effectiveLogLevel ?? "(unknown)")\n"
        out += "dry_run: \(effectiveDryRun.map(String.init(describing:)) ?? "(unknown)")\n\n"

        out += "[launchagent]\n"
        out += "installed: \(launchAgentInstalled)\n"
        if let path = launchAgentPlistPath {
            out += "plist: \(path)\n"
        }
        if let log = logTailPath {
            out += "log: \(log)\n"
        }
        out += "\n"

        if let health {
            out += renderHealth(health)
        }

        out += "[recent-decisions]\n"
        if decisions.isEmpty {
            out += "(none)\n"
        } else {
            for decision in decisions {
                out += "  \(format(decision))\n"
            }
        }
        return out
    }

    private func renderHealth(_ health: RuntimeHealthSnapshot) -> String {
        """
        [runtime-health]
        ticks: \(health.ticks)
        skipped_asleep: \(health.skippedAsleep)
        skipped_not_visible: \(health.skippedNotVisible)
        skipped_grace: \(health.skippedGrace)
        skipped_implicit_wake: \(health.skippedImplicitWake)
        config_updates: \(health.configUpdates)
        ax_unknown_inspections: \(health.axUnknownInspections)
        ax_unreadable_windows: \(health.axUnreadableWindows)
        checkpoint_save_failures: \(health.checkpointSaveFailures)\n\n
        """
    }

    private func format(_ decision: Decision) -> String {
        switch decision {
        case .ignore(let id):
            "ignore   \(id.value)"
        case .track(let id, _):
            "track    \(id.value)"
        case .evict(let id, let pids):
            "evict    \(id.value) pids=\(pids.sorted())"
        case .cooldown(let id, _):
            "cooldown \(id.value)"
        }
    }
}
