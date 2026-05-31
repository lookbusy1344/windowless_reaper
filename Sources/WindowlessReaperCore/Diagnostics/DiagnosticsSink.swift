import Foundation
import Logging

/// Codable projection of a `Decision` for cross-process persistence.
///
/// `Decision` carries `SuspendingClock.Instant`s that are meaningless across
/// process boundaries (and not `Codable`), so the persisted form keeps only
/// what `wreaper diagnose` renders: the kind, the bundle ID, and — for
/// evictions — the PID set. The dropped instants are never displayed.
public struct PersistedDecision: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case ignore
        case track
        case evict
        case cooldown
    }

    public let kind: Kind
    public let bundleID: String
    public let pids: [pid_t]?

    public init(kind: Kind, bundleID: String, pids: [pid_t]? = nil) {
        self.kind = kind
        self.bundleID = bundleID
        self.pids = pids
    }

    public init(_ decision: Decision) {
        switch decision {
        case .ignore(let id):
            self.init(kind: .ignore, bundleID: id.value)
        case .track(let id, _):
            self.init(kind: .track, bundleID: id.value)
        case .evict(let id, let pids):
            self.init(kind: .evict, bundleID: id.value, pids: pids.sorted())
        case .cooldown(let id, _):
            self.init(kind: .cooldown, bundleID: id.value)
        }
    }

    /// Reconstruct a `Decision` for rendering. The instant-bearing cases
    /// (`track`, `cooldown`) are rebuilt with a placeholder `now` — diagnose's
    /// renderer ignores those instants, so no information that survives the
    /// round-trip is lost.
    public func toDecision(now: SuspendingClock.Instant = SuspendingClock.now) -> Decision {
        let id = BundleID(bundleID)
        switch kind {
        case .ignore: return .ignore(id)
        case .track: return .track(id, since: now)
        case .evict: return .evict(id, pids: Set(pids ?? []))
        case .cooldown: return .cooldown(id, until: now)
        }
    }
}

/// Versioned envelope persisted to the diagnostics sidecar. Carries the
/// daemon's recent-decision ring and the latest runtime-health counters so
/// the out-of-process `wreaper diagnose` can render both.
public struct DiagnosticsSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public let version: Int
    public let decisions: [PersistedDecision]
    public let health: RuntimeHealthSnapshot?

    public init(
        decisions: [PersistedDecision],
        health: RuntimeHealthSnapshot?,
        version: Int = DiagnosticsSnapshot.currentVersion
    ) {
        self.version = version
        self.decisions = decisions
        self.health = health
    }
}

/// Write seam for the engine's diagnostics. The daemon and `wreaper diagnose`
/// run as separate processes, so the in-memory `DecisionRing` and
/// `RuntimeHealth` counters are unreachable from the tool; this sidecar
/// bridges them. Reading is a diagnose-only concern and lives on the concrete
/// file impl.
public protocol DiagnosticsSink: Sendable {
    /// Atomically overwrite the sidecar with the supplied decisions (newest
    /// last) and the latest runtime-health snapshot.
    func write(decisions: [Decision], health: RuntimeHealthSnapshot) async
}

/// File-backed `DiagnosticsSink`. Mirrors `FileCheckpointer`: pretty JSON,
/// atomic replacement, lenient reads that never crash on bad input.
public struct FileDiagnosticsSink: DiagnosticsSink {
    private let url: URL
    private let logger: Logger

    public init(url: URL, logger: Logger = Logger(label: "wreaper.diagnostics")) {
        self.url = url
        self.logger = logger
    }

    /// `~/Library/Application Support/windowless-reaper/diagnostics.json`,
    /// alongside the checkpoint.
    public static func defaultURL(paths: UserPaths = UserPaths()) -> URL {
        paths.homeDirectory
            .appendingPathComponent("Library/Application Support/windowless-reaper/diagnostics.json")
    }

    public func write(decisions: [Decision], health: RuntimeHealthSnapshot) async {
        let snapshot = DiagnosticsSnapshot(
            decisions: decisions.map(PersistedDecision.init),
            health: health
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("diagnostics sidecar write failed: \(error)")
        }
    }

    /// Read the persisted snapshot, or `nil` if absent/corrupt/unknown-version.
    public func read() async -> DiagnosticsSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)
            guard snapshot.version == DiagnosticsSnapshot.currentVersion else {
                logger.warning("diagnostics sidecar version=\(snapshot.version) unknown — ignoring")
                return nil
            }
            return snapshot
        } catch {
            logger.warning("diagnostics sidecar read failed: \(error)")
            return nil
        }
    }
}
