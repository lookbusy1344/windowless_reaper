import Foundation
import TOMLKit

public enum ConfigLoader {
    public static func load(from url: URL) throws -> Config {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.fileNotFound(url.path)
        }
        return try load(toml: content)
    }

    public static func load(toml: String) throws -> Config {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: toml)
        } catch let error as TOMLParseError {
            throw ConfigError.parseError(
                line: error.source.begin.line,
                column: error.source.begin.column,
                message: error.description
            )
        } catch {
            throw ConfigError.parseError(line: 0, column: 0, message: error.localizedDescription)
        }

        for (key, _) in table where !Self.knownTopLevelKeys.contains(key) {
            throw ConfigError.unknownTopLevelKey(key: key)
        }

        let settings = try parseSettings(table["settings"]?.table)
        let rules = try parseRules(table["apps"]?.table, settings: settings)
        return Config(settings: settings, rules: rules)
    }

    /// Sentinel value meaning "no active rule" — for `timeout`, the bundle is
    /// allowlisted but never reaped; for `cooldown`, fall back to
    /// `settings.default_cooldown` (same as omitting the key).
    static let noneSentinel = "none"
    /// Sentinel meaning "inherit `settings.default_timeout`".
    static let defaultSentinel = "default"

    private static let knownTopLevelKeys = Set(ConfigSchema.TopLevelKey.allCases.map(\.rawValue))
    private static let knownSettingsKeys = Set(ConfigSchema.SettingsKey.allCases.map(\.rawValue))
    private static let knownRuleKeys = Set(ConfigSchema.RuleKey.allCases.map(\.rawValue))
    private static let knownLogLevels = Set(ConfigSchema.LogLevel.allCases.map(\.rawValue))

    private static func parseSettings(_ table: TOMLTable?) throws -> Settings {
        guard let table else { return Settings.defaults }

        for (key, _) in table where !Self.knownSettingsKeys.contains(key) {
            throw ConfigError.unknownSettingsKey(key: key)
        }

        let pollInterval = try table["poll_interval"]?.string.map { try Duration(string: $0) }
            ?? Settings.defaults.pollInterval
        let logLevel = table["log_level"]?.string ?? Settings.defaults.logLevel
        if !Self.knownLogLevels.contains(logLevel) {
            throw ConfigError.invalidLogLevel(value: logLevel)
        }
        let dryRun = table["dry_run"]?.bool ?? Settings.defaults.dryRun
        let defaultCooldown = try table["default_cooldown"]?.string.map { try Cooldown(string: $0) }
            ?? Settings.defaults.defaultCooldown
        let defaultTimeout: Duration?
        if let raw = table["default_timeout"]?.string {
            do {
                defaultTimeout = try Duration(string: raw)
            } catch {
                throw ConfigError.invalidDefaultTimeout(value: raw, underlying: error)
            }
        } else {
            defaultTimeout = nil
        }
        let clearCooldown: Duration
        if let raw = table["clear_cooldown"]?.string {
            do {
                clearCooldown = try Duration(string: raw)
            } catch {
                throw ConfigError.invalidClearCooldown(value: raw, underlying: error)
            }
        } else {
            clearCooldown = Settings.defaults.clearCooldown
        }
        let adaptivePressure = table["adaptive_pressure"]?.bool ?? Settings.defaults.adaptivePressure

        return Settings(
            pollInterval: pollInterval,
            logLevel: logLevel,
            dryRun: dryRun,
            defaultCooldown: defaultCooldown,
            defaultTimeout: defaultTimeout,
            clearCooldown: clearCooldown,
            adaptivePressure: adaptivePressure
        )
    }

    private static func parseRules(_ appsTable: TOMLTable?, settings: Settings) throws -> [BundleID: Rule] {
        guard let appsTable else { return [:] }

        var rules: [BundleID: Rule] = [:]
        for (key, value) in appsTable {
            guard let ruleTable = value.table else {
                throw ConfigError.invalidRuleValue(bundleID: key)
            }
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigError.invalidBundleID(key)
            }
            let bundleID = BundleID(key)
            let rule = try parseRule(bundleID: key, table: ruleTable, settings: settings)
            rules[bundleID] = rule
        }
        return rules
    }

    private static func parseRule(bundleID: String, table: TOMLTable, settings: Settings) throws -> Rule {
        for (key, _) in table where !knownRuleKeys.contains(key) {
            throw ConfigError.unknownRuleKey(bundleID: bundleID, key: key)
        }
        guard let timeoutStr = table["timeout"]?.string else {
            throw ConfigError.missingTimeout(bundleID: bundleID)
        }
        let timeout: Duration?
        if timeoutStr == Self.noneSentinel {
            timeout = nil
        } else if timeoutStr == Self.defaultSentinel {
            guard let fallback = settings.defaultTimeout else {
                throw ConfigError.defaultTimeoutNotSet(bundleID: bundleID)
            }
            timeout = fallback
        } else {
            do {
                timeout = try Duration(string: timeoutStr)
            } catch {
                throw ConfigError.invalidDuration(bundleID: bundleID, value: timeoutStr, underlying: error)
            }
        }

        let cooldown: Cooldown?
        if let cooldownStr = table["cooldown"]?.string, cooldownStr != Self.noneSentinel {
            do {
                cooldown = try Cooldown(string: cooldownStr)
            } catch {
                throw ConfigError.invalidCooldown(bundleID: bundleID, value: cooldownStr, underlying: error)
            }
        } else {
            cooldown = nil
        }

        return Rule(timeout: timeout, cooldown: cooldown)
    }
}

public enum ConfigError: Error {
    case fileNotFound(String)
    case parseError(line: Int, column: Int, message: String)
    case missingTimeout(bundleID: String)
    case invalidDuration(bundleID: String, value: String, underlying: any Error)
    case invalidCooldown(bundleID: String, value: String, underlying: any Error)
    case invalidRuleValue(bundleID: String)
    case unknownTopLevelKey(key: String)
    case unknownSettingsKey(key: String)
    case unknownRuleKey(bundleID: String, key: String)
    case invalidLogLevel(value: String)
    case invalidDefaultTimeout(value: String, underlying: any Error)
    case defaultTimeoutNotSet(bundleID: String)
    case invalidClearCooldown(value: String, underlying: any Error)
    case invalidBundleID(_ id: String)
}

public extension ConfigError {
    var userFacingMessage: String {
        switch self {
        case .fileNotFound(let path):
            "No config at \(path)."
        case .parseError(let line, let col, let msg):
            "Parse error at line \(line), column \(col): \(msg)"
        case .missingTimeout(let id):
            "App '\(id)' is missing required 'timeout' key."
        case .invalidDuration(let id, let val, let err):
            "App '\(id)' has invalid timeout '\(val)': \(err)"
        case .invalidCooldown(let id, let val, let err):
            "App '\(id)' has invalid cooldown '\(val)': \(err)"
        case .invalidRuleValue(let id):
            "App '\(id)' must be a TOML table."
        case .unknownTopLevelKey(let key):
            "Unknown top-level key '\(key)'. Allowed: \(ConfigSchema.TopLevelKey.bracketedAllowedText)."
        case .unknownSettingsKey(let key):
            "Unknown key '[settings].\(key)'. Allowed: \(ConfigSchema.SettingsKey.allowedText)."
        case .unknownRuleKey(let id, let key):
            "Unknown key '[apps.\(id)].\(key)'. Allowed: \(ConfigSchema.RuleKey.allowedText)."
        case .invalidLogLevel(let value):
            "Invalid log_level '\(value)'. Allowed: \(ConfigSchema.LogLevel.allowedText)."
        case .invalidDefaultTimeout(let val, let err):
            "Invalid '[settings].default_timeout' value '\(val)': \(err)"
        case .defaultTimeoutNotSet(let id):
            "App '\(id)' uses timeout = \"default\" but '[settings].default_timeout' is not set."
        case .invalidClearCooldown(let val, let err):
            "Invalid '[settings].clear_cooldown' value '\(val)': \(err)"
        case .invalidBundleID(let id):
            "Invalid bundle ID '\(id)' — must be a non-empty string."
        }
    }
}
