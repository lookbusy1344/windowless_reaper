import Foundation

/// Writes the LaunchAgent plist and bootstraps it via the injected
/// `LaunchctlClient`. Uninstall reverses both steps. Atomic write so a
/// crash mid-install never leaves a partial plist on disk.
public struct LaunchAgentInstaller: Sendable {
    public let plistURL: URL
    public let binaryPath: String
    public let home: String
    public let launchctl: any LaunchctlClient

    public init(
        plistURL: URL,
        binaryPath: String,
        home: String,
        launchctl: any LaunchctlClient
    ) {
        self.plistURL = plistURL
        self.binaryPath = binaryPath
        self.home = home
        self.launchctl = launchctl
    }

    /// Render the plist and the launchctl commands that `install`/`uninstall`
    /// will run. Returns a deterministic, multi-section string suitable for
    /// `--print-only` dry runs and for documentation.
    public func renderPlanSummary(uid: uid_t) -> String {
        var out = ""
        out += "[plist target]\n\(plistURL.path)\n\n"
        out += "[plist contents]\n"
        out += LaunchAgentPlist.render(binaryPath: binaryPath, home: home)
        out += "\n\n[install actions]\n"
        out += "mkdir -p \(plistURL.deletingLastPathComponent().path)\n"
        out += "write \(plistURL.path) (atomic, utf-8)\n"
        out += "launchctl bootstrap gui/\(uid) \(plistURL.path)\n\n"
        out += "[uninstall actions]\n"
        out += "launchctl bootout gui/\(uid) \(plistURL.path) (tolerated if not loaded)\n"
        out += "rm \(plistURL.path) (tolerated if absent)\n"
        return out
    }

    /// Install. If the plist already exists, `force` must be true; otherwise
    /// throws `InstallError.alreadyInstalled` with the existing path so the
    /// CLI can print a clear remediation.
    public func install(uid: uid_t, force: Bool = false) async throws {
        if FileManager.default.fileExists(atPath: plistURL.path), !force {
            throw InstallError.alreadyInstalled(plistURL.path)
        }
        if !FileManager.default.isExecutableFile(atPath: binaryPath) {
            throw InstallError.binaryNotExecutable(binaryPath)
        }
        let xml = LaunchAgentPlist.render(binaryPath: binaryPath, home: home)
        let parent = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try xml.write(to: plistURL, atomically: true, encoding: .utf8)
        try await launchctl.bootstrap(plistPath: plistURL.path, uid: uid)
    }

    /// Uninstall. Idempotent: missing plist and "service not loaded" are not
    /// errors. Real launchctl errors that are not the "not loaded" shape are
    /// surfaced; the CLI can decide whether to ignore them.
    public func uninstall(uid: uid_t) async throws {
        do {
            try await launchctl.bootout(plistPath: plistURL.path, uid: uid)
        } catch let error as LaunchctlError where error.isNotLoaded {
            // Service was already not loaded — fine.
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

public enum InstallError: Error, Equatable {
    case alreadyInstalled(String)
    case binaryNotExecutable(String)
}
