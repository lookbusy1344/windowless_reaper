import Foundation
import Logging
import os

/// Process-wide writer that owns the log file, serialises appends, and
/// rotates to a `.1` sibling when the active file exceeds `maxBytes`. One
/// sink is shared across every `RotatingFileLogHandler` instance so the
/// per-call cost is a single lock + write.
///
/// Rotation policy: one backup generation. When a write pushes the file
/// over the threshold, the active file is closed, renamed over `<name>.1`
/// (replacing any prior backup), and a fresh empty file is opened. Worst
/// case on-disk footprint is therefore ~2 × maxBytes.
public final class RotatingFileSink: Sendable {
    private let path: URL
    private let backupPath: URL
    private let maxBytes: Int
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private let watchQueue = DispatchQueue(label: "wreaper.log.sink-watcher", qos: .utility)

    private struct State {
        var handle: FileHandle?
        var bytesWritten: Int = 0
        var watcher: (any DispatchSourceFileSystemObject)?
    }

    public init(path: URL, maxBytes: Int) {
        self.path = path
        backupPath = path.appendingPathExtension("1")
        self.maxBytes = maxBytes
    }

    deinit {
        // Cancel must precede FD close — the watcher owns a dup'd FD that
        // its cancel handler will close. The FileHandle owns the original.
        lock.withLock { state in
            closeHandle(&state)
        }
    }

    public func write(_ line: String) {
        let data = Data(line.utf8)
        lock.withLock { state in
            ensureHandle(&state)
            guard let handle = state.handle else { return }
            do {
                try handle.write(contentsOf: data)
                state.bytesWritten = try Int(handle.seekToEnd())
                if state.bytesWritten >= maxBytes {
                    rotate(&state)
                }
            } catch {
                closeHandle(&state)
                reportError(error)
            }
        }
    }

    /// Flush the active file handle. Used from signal handlers and at
    /// shutdown so the last few seconds of logs are not lost when stderr is
    /// block-buffered behind a file redirection upstream.
    public func flush() {
        lock.withLock { state in
            try? state.handle?.synchronize()
        }
    }

    /// Close the active handle so the next write re-opens the path. Intended
    /// for SIGHUP, after an external rotator has renamed or replaced the log
    /// file: a long-lived `FileHandle` is bound to the inode, so writes that
    /// follow an external rename would otherwise land in an orphaned inode
    /// invisible to `ls`. The reopen is lazy — the file is not recreated
    /// here, only on the next `write(_:)`. Auto-recovery via the vnode
    /// watcher covers the same case for non-cooperating writers; this entry
    /// point remains as a deterministic manual escape hatch.
    public func reopen() {
        lock.withLock { state in
            try? state.handle?.synchronize()
            closeHandle(&state)
        }
    }

    private func ensureHandle(_ state: inout State) {
        if state.handle != nil { return }
        state.bytesWritten = 0
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: path.path) {
                fm.createFile(atPath: path.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: path)
            let end = try handle.seekToEnd()
            state.bytesWritten = Int(end)
            state.handle = handle
            installWatcher(&state, fd: handle.fileDescriptor)
        } catch {
            reportError(error)
        }
    }

    /// Installs a vnode dispatch source that fires when another process
    /// renames, deletes, or revokes the file the daemon currently has
    /// open. On any such event we drop the handle so the next `write(_:)`
    /// re-opens at `path` — auto-recovery for atomic edits from editors,
    /// `mv`, `rm`, or external rotators that don't send SIGHUP.
    ///
    /// The source is bound to a **dup**'d FD so its lifecycle is
    /// independent of the `FileHandle` we hand back to the writer. The
    /// cancel handler closes the dup; `FileHandle` separately owns the
    /// original. This avoids the "close before cancel" trap in
    /// libdispatch (which can fire spurious events) and the symmetric
    /// "cancel without closing FD" leak.
    private func installWatcher(_ state: inout State, fd: Int32) {
        let dupFd = dup(fd)
        guard dupFd >= 0 else {
            reportError(POSIXError(.init(rawValue: errno) ?? .EBADF))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dupFd,
            eventMask: [.delete, .rename, .revoke],
            queue: watchQueue
        )
        source.setCancelHandler { close(dupFd) }
        source.setEventHandler { [weak self] in self?.handleVNodeEvent() }
        state.watcher = source
        source.resume()
    }

    private func handleVNodeEvent() {
        lock.withLock { state in
            closeHandle(&state)
        }
        // Lazy: ensureHandle runs on the next write. No need to recreate
        // the file eagerly — if no further writes arrive, there's no log
        // to lose.
    }

    /// Single teardown path for the handle + watcher pair. Cancelling the
    /// watcher before closing the handle is fine: the watcher's FD is a
    /// dup, so cancelling closes only that dup and the FileHandle's FD
    /// remains valid until we close it ourselves.
    private func closeHandle(_ state: inout State) {
        state.watcher?.cancel()
        state.watcher = nil
        try? state.handle?.close()
        state.handle = nil
        state.bytesWritten = 0
    }

    private func rotate(_ state: inout State) {
        closeHandle(&state)
        let fm = FileManager.default
        // First rotation has no prior backup — only remove if one exists so a
        // benign "fileNoSuchFile" doesn't burn the one-shot stderr latch and
        // suppress later genuine errors.
        if fm.fileExists(atPath: backupPath.path) {
            do { try fm.removeItem(at: backupPath) } catch { reportError(error) }
        }
        do { try fm.moveItem(at: path, to: backupPath) } catch { reportError(error) }
        ensureHandle(&state)
    }

    /// Reports an error to stderr, at most once per process lifetime, so a
    /// failing log destination does not flood the error stream.
    private func reportError(_ error: any Error) {
        Self.errorReported.withLock { alreadyReported in
            guard !alreadyReported else { return }
            alreadyReported = true
            let msg = "\(Date().ISO8601Format()) [wreaper] RotatingFileSink: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(msg.utf8))
        }
    }

    private static let errorReported = OSAllocatedUnfairLock<Bool>(initialState: false)
}

/// `LogHandler` that writes through a shared `RotatingFileSink`. Defaults
/// to `LogLevelBootstrap.currentLevel` so hot reload affects every logger,
/// but an explicit `logger.logLevel = .x` assignment is honoured on that
/// handler only — matching the `swift-log` contract.
struct RotatingFileLogHandler: LogHandler {
    private let label: String
    private let sink: RotatingFileSink
    private var logLevelOverride: Logging.Logger.Level?
    var metadata: Logging.Logger.Metadata = [:]

    var logLevel: Logging.Logger.Level {
        get { logLevelOverride ?? LogLevelBootstrap.currentLevel }
        set { logLevelOverride = newValue }
    }

    init(label: String, sink: RotatingFileSink) {
        self.label = label
        self.sink = sink
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        let ts = Self.timestamp()
        var line = "\(ts) \(event.level) \(label):"
        let combined = metadata.merging(event.metadata ?? [:]) { _, new in new }
        if !combined.isEmpty {
            let pretty = combined.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            line += " " + pretty
        }
        line += " [\(event.source)] \(event.message)\n"
        sink.write(line)
    }

    private static func timestamp() -> String {
        var buf = [UInt8](repeating: 0, count: 64)
        var now = time(nil)
        var tmStorage = tm()
        let tm = localtime_r(&now, &tmStorage)
        let written = buf.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: ptr.count) {
                    strftime($0, ptr.count, "%Y-%m-%dT%H:%M:%S%z", tm)
                }
            } ?? 0
        }
        return String(bytes: buf.prefix(written), encoding: .utf8) ?? ""
    }
}
