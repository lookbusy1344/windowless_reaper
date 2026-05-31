import Foundation
import Logging

/// File-system watcher that emits parse `Result`s whenever the config file
/// changes. Hot-reload consumers iterate `events`; lifecycle is controlled by
/// `start()` / `stop()`, both of which are idempotent.
///
/// Concurrency: state is isolated to the actor. The Dispatch source runs on a
/// dedicated serial queue and forwards events through a single Sendable
/// continuation. The underlying file descriptor is closed exactly once via the
/// source's cancel handler.
///
/// Rearm: atomic-replace saves (vim, VS Code, `FileManager.replaceItem`,
/// `String.write(...atomic:)`) unlink the inode our FD points at. After the
/// first `.rename`/`.delete` event we cancel the source, close the old FD,
/// and re-open against the new inode so subsequent edits keep firing.
public actor ConfigWatcher {
    /// Editor `rename()` is a single syscall and the gap between unlink and
    /// the new entry is microseconds in practice, but non-atomic editors
    /// (write-then-rename in two steps) need a brief retry window.
    private static let rearmRetryCount = 5
    private static let rearmRetryDelay: Swift.Duration = .milliseconds(100)

    public nonisolated let events: AsyncStream<Result<Config, any Error>>
    private nonisolated let continuation: AsyncStream<Result<Config, any Error>>.Continuation
    private nonisolated let queue = DispatchQueue(label: "com.wreaper.config-watcher")
    private let url: URL
    private let logger: Logger
    private var source: (any DispatchSourceFileSystemObject)?

    public init(url: URL, logger: Logger = Logger(label: "wreaper.config-watcher")) {
        self.url = url
        self.logger = logger
        var capturedContinuation: AsyncStream<Result<Config, any Error>>.Continuation!
        // Coalesce rapid bursts (an editor save can fire .write and .rename
        // back-to-back) into a single reload — the consumer reads the file
        // once and gets the current contents anyway.
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    /// Start watching. No-op if already running.
    public func start() {
        guard source == nil else { return }
        openSource()
    }

    /// Stop watching. No-op if already stopped. The event stream remains usable
    /// — subsequent `start()` calls resume delivery.
    public func stop() {
        source?.cancel()
        source = nil
    }

    /// Stop watching and terminate the event stream.
    public func finish() {
        stop()
        continuation.finish()
    }

    public func isRunning() -> Bool {
        source != nil
    }

    // MARK: - Private

    private func openSource() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("config watcher could not open \(url.path) (errno=\(errno))")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let src else { return }
            // DispatchSource.FileSystemEvent is not Sendable; ship the raw
            // bitmask through the actor hop and reconstruct on the other side.
            let rawFlags = src.data.rawValue
            Task { [weak self] in
                await self?.handleEvent(flags: DispatchSource.FileSystemEvent(rawValue: rawFlags))
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func handleEvent(flags: DispatchSource.FileSystemEvent) async {
        let result = Result { try ConfigLoader.load(from: url) }
        continuation.yield(result)
        if flags.contains(.rename) || flags.contains(.delete) {
            await rearm()
        }
    }

    private func rearm() async {
        source?.cancel()
        source = nil
        for attempt in 0 ..< Self.rearmRetryCount {
            openSource()
            if source != nil {
                if attempt > 0 {
                    logger.notice("config watcher rearmed after \(attempt) retr\(attempt == 1 ? "y" : "ies")")
                } else {
                    logger.notice("config watcher rearmed")
                }
                return
            }
            try? await Task.sleep(for: Self.rearmRetryDelay)
        }
        logger.warning("config watcher failed to rearm after \(Self.rearmRetryCount) attempts; hot reload paused")
    }
}
