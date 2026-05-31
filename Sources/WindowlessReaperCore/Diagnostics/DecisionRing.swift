/// Bounded ring buffer of recent engine decisions, drained by `wreaper
/// diagnose`. The engine pushes after every tick; the ring discards the
/// oldest entry once `capacity` is exceeded. Kept as an actor so the engine
/// and the diagnose command can read concurrently without locks.
///
/// Uses `Array.removeFirst()` (O(n) per eviction) rather than a head-index
/// ring backed by `ContiguousArray<Decision?>`. At the default capacity (32)
/// the cost is negligible. If profiling ever shows this as a hot spot,
/// switch to the head-index approach — but document the trade-off so the
/// next editor doesn't "improve" it without measuring.
public actor DecisionRing {
    public static let defaultCapacity = 32

    private var buffer: [Decision] = []
    public let capacity: Int

    public init(capacity: Int = DecisionRing.defaultCapacity) {
        precondition(capacity > 0, "DecisionRing capacity must be positive")
        self.capacity = capacity
        buffer.reserveCapacity(capacity)
    }

    public func record(_ decision: Decision) {
        if buffer.count == capacity {
            buffer.removeFirst()
        }
        buffer.append(decision)
    }

    public func recordAll(_ decisions: [Decision]) {
        for decision in decisions {
            record(decision)
        }
    }

    public func snapshot() -> [Decision] {
        buffer
    }
}
