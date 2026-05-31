import Foundation
import Logging
import os

/// Single bootstrap path for CLI logging. CLI `--log-level` overrides the
/// config `[settings].log_level`. Invalid values throw before any monitoring
/// starts.
///
/// Hot reload: handlers consult `currentLevel` on every `logLevel` read, so
/// `apply(...)` after a config reload takes effect for *already-constructed*
/// loggers too — not only for new ones. swift-log's filtering reads
/// `handler.logLevel` before invoking `log(...)`, so the dynamic getter is
/// sufficient.
public enum LogLevelBootstrap {
    public static func parse(_ raw: String) throws -> Logging.Logger.Level {
        switch ConfigSchema.LogLevel(rawValue: raw.lowercased()) {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warn, .warning: .warning
        case .error: .error
        case nil: throw LogLevelError.invalid(raw)
        }
    }

    public static func resolve(cliOverride: String?, configValue: String) throws -> Logging.Logger.Level {
        if let override = cliOverride { return try parse(override) }
        return try parse(configValue)
    }

    /// Install the handler factory exactly once and set the level. Subsequent
    /// calls only update the level used by new logger handlers.
    public static func apply(_ level: Logging.Logger.Level) {
        levelStore.withLock { $0 = level }
        bootstrapOnce()
    }

    public static var currentLevel: Logging.Logger.Level {
        levelStore.withLock { $0 }
    }

    /// Default rotation threshold in bytes for the file sink. ~5 MB keeps
    /// `debug`-level steady-state under one rotation per multi-day install,
    /// while the rotation itself caps worst-case disk use at ~2 × this.
    public static let defaultLogRotateBytes = 5 * 1024 * 1024

    /// Install a rotating file sink. Must be called before any `Logger` is
    /// constructed if logs from earlier loggers are to land in the file —
    /// safe to call afterwards too, but those handlers will continue writing
    /// to stderr. Subsequent calls are ignored; the first sink wins.
    public static func installFileSink(at path: URL, maxBytes: Int = defaultLogRotateBytes) {
        sinkStore.withLock { current in
            guard current == nil else { return }
            current = RotatingFileSink(path: path, maxBytes: maxBytes)
        }
    }

    /// Flush the active file sink (if any). Intended for signal handlers and
    /// shutdown paths so the last log lines before exit are not lost.
    public static func flushSink() {
        sinkStore.withLock { $0?.flush() }
    }

    /// Drop the active sink's file handle so the next write re-opens the
    /// configured path. Intended for SIGHUP after an external log-rotation
    /// tool renames or replaces the log file.
    public static func reopenSink() {
        sinkStore.withLock { $0?.reopen() }
    }

    static var sink: RotatingFileSink? {
        sinkStore.withLock { $0 }
    }

    private static let levelStore = OSAllocatedUnfairLock<Logging.Logger.Level>(initialState: .info)
    private static let bootstrapFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let sinkStore = OSAllocatedUnfairLock<RotatingFileSink?>(initialState: nil)

    private static func bootstrapOnce() {
        let shouldBootstrap: Bool = bootstrapFlag.withLock { flag in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldBootstrap else { return }
        LoggingSystem.bootstrap { label in
            if let sink = LogLevelBootstrap.sink {
                return RotatingFileLogHandler(label: label, sink: sink)
            }
            return DynamicLevelStreamHandler(label: label)
        }
    }
}

/// Wraps `StreamLogHandler.standardError` but resolves `logLevel` from the
/// shared `LogLevelBootstrap` state on every access. Without this, each
/// logger snapshots its level at construction and is deaf to later `apply()`
/// calls — defeating hot reload for loggers already in flight.
struct DynamicLevelStreamHandler: LogHandler {
    private var inner: StreamLogHandler

    init(label: String) {
        inner = StreamLogHandler.standardError(label: label)
    }

    var logLevel: Logging.Logger.Level {
        get { LogLevelBootstrap.currentLevel }
        set { _ = newValue } // centrally controlled
    }

    var metadata: Logging.Logger.Metadata {
        get { inner.metadata }
        set { inner.metadata = newValue }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { inner[metadataKey: key] }
        set { inner[metadataKey: key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        inner.log(event: event)
    }
}

enum LogLevelError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case .invalid(let value):
            "Invalid log level '\(value)'. Allowed: \(ConfigSchema.LogLevel.allowedText)."
        }
    }
}
