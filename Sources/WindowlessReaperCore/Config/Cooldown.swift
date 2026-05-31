public enum Cooldown: Hashable, Sendable {
    case absolute(Duration)
    case multiplier(Double)

    public init(string: String) throws {
        if string.hasSuffix("x") {
            let numStr = String(string.dropLast())
            guard let m = Double(numStr), m.isFinite, m > 0 else {
                throw CooldownError.invalidMultiplier(string)
            }
            self = .multiplier(m)
        } else {
            self = try .absolute(Duration(string: string))
        }
    }

    public func resolved(for timeout: Duration) -> Duration {
        switch self {
        case .absolute(let d):
            d
        case .multiplier(let m):
            // Compute in Double and clamp to the documented ceiling before
            // converting, so a large finite multiplier saturates instead of
            // overflowing Int and trapping. `m` is guaranteed finite by `init`.
            Duration(seconds: clamp(
                product: Double(timeout.seconds) * m,
                lower: Duration.minimum.seconds,
                upper: Duration.maximumCooldown.seconds
            ))
        }
    }
}

/// Rounds and clamps a Double cooldown (seconds) into `[lower, upper]`,
/// avoiding the `Int(Double)` trap when the product exceeds `Int.max`.
private func clamp(product: Double, lower: Int, upper: Int) -> Int {
    let rounded = product.rounded()
    if rounded >= Double(upper) { return upper }
    if rounded <= Double(lower) { return lower }
    return Int(rounded)
}

enum CooldownError: Error, Equatable {
    case invalidMultiplier(String)
}
