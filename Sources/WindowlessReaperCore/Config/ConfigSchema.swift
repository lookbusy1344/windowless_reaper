public enum ConfigSchema {
    public enum TopLevelKey: String, CaseIterable, Sendable {
        case settings
        case apps
    }

    public enum SettingsKey: String, CaseIterable, Sendable {
        case pollInterval = "poll_interval"
        case logLevel = "log_level"
        case dryRun = "dry_run"
        case defaultCooldown = "default_cooldown"
        case defaultTimeout = "default_timeout"
        case clearCooldown = "clear_cooldown"
        case adaptivePressure = "adaptive_pressure"
    }

    public enum RuleKey: String, CaseIterable, Sendable {
        case timeout
        case cooldown
    }

    public enum LogLevel: String, CaseIterable, Sendable {
        case trace
        case debug
        case info
        case notice
        case warn
        case warning
        case error
    }
}

public extension CaseIterable where Self: RawRepresentable, Self.RawValue == String {
    static var allowedText: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public extension CaseIterable where Self: RawRepresentable, Self.RawValue == String {
    static var bracketedAllowedText: String {
        allCases.map { "[\($0.rawValue)]" }.joined(separator: ", ")
    }
}
