import ArgumentParser
import Foundation
import WindowlessReaperCore

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage the wreaper configuration file.",
        subcommands: [InitSubcommand.self, ShowSubcommand.self, ValidateSubcommand.self, ScaffoldSubcommand.self]
    )

    struct InitSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Write a sample config to the default location."
        )
        @Flag(name: .long, help: "Overwrite an existing config file.")
        var force: Bool = false

        func run() async throws {
            let url = defaultConfigURL()
            if !force, FileManager.default.fileExists(atPath: url.path) {
                throw ValidationError("Config already exists at \(url.path). Use --force to overwrite.")
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ConfigSample.content.write(to: url, atomically: true, encoding: .utf8)
            print("Wrote sample config to \(url.path)")
        }
    }

    struct ShowSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the parsed config in canonical form."
        )
        @Option(name: .long, help: "Path to config file (default: ~/.config/windowless-reaper/config.toml)")
        var config: String?

        func run() async throws {
            let url = config.map { URL(fileURLWithPath: $0) } ?? defaultConfigURL()
            let cfg = try ConfigPath.load(from: url)
            print(cfg.toTOML())
        }
    }

    struct ScaffoldSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scaffold",
            abstract: "Print a starter config listing currently-running candidate apps.",
            discussion: """
            Each emitted entry has timeout = "none" so the scaffold is inert
            until you replace "none" with a real duration (e.g. "10m"). By
            default, only apps with no AX windows are listed, and Apple
            system bundles outside a small user-facing allowlist are filtered
            out.
            """
        )

        @Flag(name: .long, help: "Include every running candidate, not just windowless ones.")
        var allRunning: Bool = false

        @Flag(name: .long, help: "Include com.apple.* bundles outside the curated allowlist.")
        var includeSystem: Bool = false

        func run() async throws {
            try await CLIPermissions.requireAccessibility()

            let enumerator = NSWorkspaceAppEnumerator()
            let inspector = AXWindowInspector()
            let apps = await enumerator.enumerate()

            var states: [pid_t: WindowState] = [:]
            states.reserveCapacity(apps.count)
            for app in apps {
                states[app.pid] = await inspector.inspect(pid: app.pid).state
            }

            let bundles = ConfigScaffold.selectBundles(
                apps: apps,
                windowStates: states,
                options: ConfigScaffold.Options(
                    windowlessOnly: !allRunning,
                    includeSystem: includeSystem
                )
            )
            print(ConfigScaffold.renderTOML(bundles: bundles))
        }
    }

    struct ValidateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Validate a config file. Exits 0 if valid, non-zero otherwise."
        )
        @Argument(help: "Path to config file (default: ~/.config/windowless-reaper/config.toml)")
        var path: String?

        func run() async throws {
            let url = path.map { URL(fileURLWithPath: $0) } ?? defaultConfigURL()
            _ = try ConfigPath.load(from: url)
            print("Config at \(url.path) is valid.")
        }
    }
}

private func defaultConfigURL() -> URL {
    UserPaths().configURL
}
