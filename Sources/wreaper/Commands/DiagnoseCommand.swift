import ArgumentParser
import Darwin
import Foundation
import WindowlessReaperCore

struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Emit a self-contained diagnostic report for bug reports."
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let paths = UserPaths()
        let url = ConfigPath.resolve(override: globals.config)
        let config: Config?
        let configError: String?
        do {
            config = try ConfigLoader.load(from: url)
            configError = nil
        } catch {
            config = nil
            configError = String(describing: error)
        }

        let probe: any PermissionProbe = AccessibilityPermission()
        let trusted = await probe.isTrusted()

        let plistURL = paths.launchAgentPlistURL(label: LaunchAgentPlist.label)
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let logPath = paths.logURL(relativePath: LaunchAgentPlist.logRelativePath).path

        let effectiveLogLevel = config.map {
            globals.logLevel ?? $0.settings.logLevel
        }
        let effectiveDryRun = config.map { globals.dryRun || $0.settings.dryRun }

        // Recent decisions and health counters are written each tick by the
        // running daemon to a sidecar (the in-process DecisionRing and
        // RuntimeHealth are unreachable across processes).
        let sidecar = await FileDiagnosticsSink(url: FileDiagnosticsSink.defaultURL()).read()
        let decisions = sidecar?.decisions.map { $0.toDecision() } ?? []

        let report = DiagnoseReport(
            version: Wreaper.configuration.version,
            axTrusted: trusted,
            configPath: url.path,
            config: config,
            configError: configError,
            decisions: decisions,
            pid: getpid(),
            effectiveLogLevel: effectiveLogLevel,
            effectiveDryRun: effectiveDryRun,
            launchAgentPlistPath: installed ? plistURL.path : nil,
            launchAgentInstalled: installed,
            logTailPath: installed ? logPath : nil,
            health: sidecar?.health
        )
        print(report.render())
    }
}
