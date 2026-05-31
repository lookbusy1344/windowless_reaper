public struct Settings: Sendable {
    public let pollInterval: Duration
    public let logLevel: String
    public let dryRun: Bool
    public let defaultCooldown: Cooldown
    /// Fallback timeout for rules written as `timeout = "default"`. `nil`
    /// means no default is configured — such a rule is a load-time error.
    public let defaultTimeout: Duration?
    /// `wreaper clear` skips any bundle whose newest PID launched within
    /// this window — guards against killing apps the user just opened.
    /// Has no effect on `run`/`check`.
    public let clearCooldown: Duration
    /// When true, the engine adapts to runtime power pressure: doubles
    /// `pollInterval` on battery or Low Power Mode, and pauses evictions
    /// (still observes) when `thermalState >= .serious`. Default false —
    /// policy choice, not correctness fix. See power_man_best_practices.md
    /// §4.12.
    public let adaptivePressure: Bool

    public static let defaults = Settings(
        pollInterval: Duration(seconds: 30),
        logLevel: "info",
        dryRun: false,
        defaultCooldown: .multiplier(5.0),
        defaultTimeout: nil,
        clearCooldown: Duration(seconds: 30),
        adaptivePressure: false
    )

    public init(
        pollInterval: Duration,
        logLevel: String,
        dryRun: Bool,
        defaultCooldown: Cooldown,
        defaultTimeout: Duration? = nil,
        clearCooldown: Duration = Duration(seconds: 30),
        adaptivePressure: Bool = false
    ) {
        self.pollInterval = pollInterval
        self.logLevel = logLevel
        self.dryRun = dryRun
        self.defaultCooldown = defaultCooldown
        self.defaultTimeout = defaultTimeout
        self.clearCooldown = clearCooldown
        self.adaptivePressure = adaptivePressure
    }
}
