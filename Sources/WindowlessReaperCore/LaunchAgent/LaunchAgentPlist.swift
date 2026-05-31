import Foundation

/// Canonical LaunchAgent plist for `wreaper run`. Built from a dictionary
/// via `PropertyListSerialization` so XML escaping is handled by the
/// Foundation framework — no hand-rolled `escapeXML`.
///
/// Logging note: the daemon owns its log file directly via
/// `RotatingFileLogHandler` (see `LogLevelBootstrap.installFileSink`).
/// Launchd stdout/stderr are discarded to `/dev/null`; the bounded app log
/// lives at `logRelativePath` once bootstrap completes.
public enum LaunchAgentPlist {
    public static let label = "com.user.windowless-reaper"
    public static let logRelativePath = "Library/Logs/windowless-reaper.log"
    public static let bootstrapSinkPath = "/dev/null"

    public static func render(binaryPath: String, home _: String) -> String {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": bootstrapSinkPath,
            "StandardErrorPath": bootstrapSinkPath,
        ]
        // swiftlint:disable:next force_try
        let data = try! PropertyListSerialization.data(
            fromPropertyList: dict,
            format: PropertyListSerialization.PropertyListFormat.xml,
            options: 0
        )
        // swiftlint:disable:next force_unwrapping
        return String(bytes: data, encoding: .utf8)!
    }
}
