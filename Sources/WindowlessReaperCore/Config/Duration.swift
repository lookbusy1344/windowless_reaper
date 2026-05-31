public struct Duration: Hashable, Sendable, CustomStringConvertible {
    public let seconds: Int

    public static let minimum = Duration(seconds: 10)

    /// Upper bound for a *resolved* cooldown. Caps the multiplier path so a
    /// large-but-finite multiplier (e.g. "1e18x") saturates here instead of
    /// overflowing `Int` and trapping at eviction time. 365 days — far beyond
    /// any sane cooldown, so clamping is harmless for legitimate config.
    public static let maximumCooldown = Duration(seconds: 365 * 24 * 3600)

    /// Internal init for known-valid values (e.g., from tests or defaults).
    public init(seconds: Int) {
        self.seconds = seconds
    }

    public init(string: String) throws {
        let parsed = try Self.parse(string)
        guard parsed >= Self.minimum.seconds else {
            throw DurationError.belowMinimum(parsed, minimum: Self.minimum.seconds)
        }
        seconds = parsed
    }

    /// Canonical format: "1h30m10s", omitting zero-valued components, but always
    /// emitting at least one component (so 0s becomes "0s" — only reachable via
    /// the internal init, never from string parsing which rejects sub-minimum).
    public var formatted: String {
        var remaining = seconds
        var parts: [String] = []
        let h = remaining / 3600
        remaining -= h * 3600
        let m = remaining / 60
        remaining -= m * 60
        let s = remaining
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined()
    }

    public var description: String {
        formatted
    }

    private static func parse(_ string: String) throws -> Int {
        guard !string.isEmpty else { throw DurationError.invalidFormat(string) }

        var total = 0
        var remaining = string[string.startIndex...]
        var consumed = false

        let unitValues: [(Character, Int)] = [("h", 3600), ("m", 60), ("s", 1)]

        for (unit, multiplier) in unitValues {
            guard let unitIdx = remaining.firstIndex(of: unit) else { continue }
            let numStr = String(remaining[remaining.startIndex ..< unitIdx])
            guard let num = Int(numStr), num >= 0 else {
                throw DurationError.invalidFormat(string)
            }
            total += num * multiplier
            remaining = remaining[remaining.index(after: unitIdx)...]
            consumed = true
        }

        guard consumed, remaining.isEmpty else {
            throw DurationError.invalidFormat(string)
        }

        return total
    }
}

enum DurationError: Error, Equatable {
    case invalidFormat(String)
    case belowMinimum(Int, minimum: Int)
}
