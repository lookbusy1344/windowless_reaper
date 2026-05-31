public struct Rule: Sendable {
    /// `nil` (TOML `"none"`) means the bundle is allowlisted but never reaped.
    /// Lets the user scaffold an entry up-front and flip it to an active
    /// timeout later without re-adding the bundle.
    public let timeout: Duration?
    public let cooldown: Cooldown?

    public init(timeout: Duration?, cooldown: Cooldown? = nil) {
        self.timeout = timeout
        self.cooldown = cooldown
    }
}
