import ArgumentParser
import Foundation
import WindowlessReaperCore

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install wreaper as a per-user LaunchAgent.",
        discussion: """
        Use `--print-only` to preview the plist and launchctl actions without
        touching the filesystem or launchd. Use `--force` to overwrite an
        existing plist (a normal reinstall refuses to clobber).
        """
    )

    @Flag(name: .long, help: "Install for the current user. Required.") var user: Bool = false
    @Option(name: .long, help: "Override the binary install prefix (e.g. /opt/homebrew).") var prefix: String?
    @Flag(name: .long, help: "Render the plist and intended launchctl actions; do not mutate.") var printOnly: Bool = false
    @Flag(name: .long, help: "Replace an existing plist (default refuses to clobber).") var force: Bool = false

    func run() async throws {
        guard user else {
            throw ValidationError("'wreaper install' requires --user (system-wide install is not supported).")
        }
        let paths = UserPaths()
        let homebrew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"]
        let binaryPath = InstallPathResolver.resolve(prefix: prefix, homebrewPrefix: homebrew)
        let plistURL = paths.launchAgentPlistURL(label: LaunchAgentPlist.label)
        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: binaryPath,
            home: paths.homeDirectory.path,
            launchctl: SystemLaunchctlClient()
        )

        if printOnly {
            print(installer.renderPlanSummary(uid: getuid()))
            return
        }

        do {
            try await installer.install(uid: getuid(), force: force)
        } catch InstallError.alreadyInstalled(let path) {
            throw ValidationError(
                "Already installed at \(path). Pass --force to replace it, or run 'wreaper uninstall --user' first."
            )
        } catch InstallError.binaryNotExecutable(let path) {
            throw ValidationError(
                "Binary not found or not executable at \(path). Build and copy it first, or pass --prefix."
            )
        }
        print("installed: \(plistURL.path)")
        print("inspect status: launchctl print gui/\(getuid())/\(LaunchAgentPlist.label)")
    }
}

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the per-user wreaper LaunchAgent."
    )

    @Flag(name: .long, help: "Uninstall for the current user. Required.") var user: Bool = false
    @Flag(name: .long, help: "Show the intended launchctl/filesystem actions; do not mutate.") var printOnly: Bool = false

    func run() async throws {
        guard user else {
            throw ValidationError("'wreaper uninstall' requires --user.")
        }
        let paths = UserPaths()
        let plistURL = paths.launchAgentPlistURL(label: LaunchAgentPlist.label)
        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: "",
            home: paths.homeDirectory.path,
            launchctl: SystemLaunchctlClient()
        )

        if printOnly {
            print(installer.renderPlanSummary(uid: getuid()))
            return
        }

        let existed = FileManager.default.fileExists(atPath: plistURL.path)
        try await installer.uninstall(uid: getuid())
        if existed {
            print("uninstalled: \(plistURL.path)")
        } else {
            print("nothing to uninstall (no plist at \(plistURL.path))")
        }
    }
}
