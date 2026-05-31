import Foundation
import Logging

/// Durable persistence layer for `TrackerSnapshot`. The engine writes a
/// checkpoint on `willSleep` so a daemon crash mid-sleep (or a clean
/// SIGTERM at logout) does not erase per-bundle "windowless since" state.
///
/// Per power_man_best_practices.md §§4.11, 4.16, the checkpoint must use
/// `Data.write(to:options:.atomic)` so a power-failure mid-write cannot
/// corrupt the file.
public protocol Checkpointer: Sendable {
    /// Atomically persist `snapshot`. Throws on I/O failure; callers
    /// decide whether to log-and-continue or surface the error.
    func save(_ snapshot: TrackerSnapshot) async throws

    /// Load the previous checkpoint, or `nil` if none exists or the
    /// payload is corrupt/unreadable/from an unknown schema version. The
    /// caller should treat `nil` as "start from t=0" — never crash.
    func load() async -> TrackerSnapshot?
}

/// File-backed `Checkpointer`. Writes JSON to a single document with
/// atomic file replacement.
public struct FileCheckpointer: Checkpointer {
    private let url: URL
    private let logger: Logger

    public init(url: URL, logger: Logger = Logger(label: "wreaper.checkpoint")) {
        self.url = url
        self.logger = logger
    }

    /// Resolve the default checkpoint location under
    /// `~/Library/Application Support/windowless-reaper/state.json`. The
    /// directory is created lazily on first write.
    public static func defaultURL(paths: UserPaths = UserPaths()) -> URL {
        paths.homeDirectory
            .appendingPathComponent("Library/Application Support/windowless-reaper/state.json")
    }

    public func save(_ snapshot: TrackerSnapshot) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        logger.debug("checkpoint saved entries=\(snapshot.entries.count) path=\(url.path)")
    }

    public func load() async -> TrackerSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning("checkpoint load failed: \(error) — starting from t=0")
            return nil
        }
        let snapshot: TrackerSnapshot
        do {
            snapshot = try JSONDecoder().decode(TrackerSnapshot.self, from: data)
        } catch {
            logger.warning("checkpoint decode failed: \(error) — starting from t=0")
            return nil
        }
        guard snapshot.version == TrackerSnapshot.currentVersion else {
            logger.warning(
                "checkpoint version=\(snapshot.version) unknown (expected \(TrackerSnapshot.currentVersion)) — starting from t=0"
            )
            return nil
        }
        return snapshot
    }
}
