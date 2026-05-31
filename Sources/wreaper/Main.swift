import ArgumentParser

@main
struct Wreaper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wreaper",
        abstract: "Reap windowless background apps after a configured timeout.",
        version: "\(BuildInfo.version) (\(BuildInfo.commit))",
        subcommands: [
            RunCommand.self,
            CheckCommand.self,
            ClearCommand.self,
            StatusCommand.self,
            PermissionsCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            ConfigCommand.self,
            DiagnoseCommand.self,
        ]
    )
}
