import Foundation
import TOMLKit

public struct Config: Sendable {
    public let settings: Settings
    public let rules: [BundleID: Rule]

    public init(settings: Settings, rules: [BundleID: Rule]) {
        self.settings = settings
        self.rules = rules
    }

    public func toTOML() -> String {
        let settingsTable = TOMLTable()
        settingsTable["poll_interval"] = settings.pollInterval.formatted
        settingsTable["log_level"] = settings.logLevel
        settingsTable["dry_run"] = settings.dryRun
        settingsTable["default_cooldown"] = cooldownString(settings.defaultCooldown)
        if let defaultTimeout = settings.defaultTimeout {
            settingsTable["default_timeout"] = defaultTimeout.formatted
        }
        settingsTable["clear_cooldown"] = settings.clearCooldown.formatted
        settingsTable["adaptive_pressure"] = settings.adaptivePressure

        let root = TOMLTable()
        root["settings"] = settingsTable

        let appsTable = TOMLTable()
        for (bundleID, rule) in rules.sorted(by: { $0.key.value < $1.key.value }) {
            let appTable = TOMLTable()
            if let timeout = rule.timeout {
                appTable["timeout"] = timeout.formatted
            } else {
                appTable["timeout"] = "none"
            }
            if let cooldown = rule.cooldown {
                appTable["cooldown"] = cooldownString(cooldown)
            }
            appsTable[bundleID.value] = appTable
        }
        root["apps"] = appsTable

        return root.convert()
    }

    private func cooldownString(_ cooldown: Cooldown) -> String {
        switch cooldown {
        case .absolute(let d): return d.formatted
        case .multiplier(let m):
            let s = m.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(m))
                : String(m)
            return "\(s)x"
        }
    }
}
