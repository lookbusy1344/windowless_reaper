import ArgumentParser

@main
struct Wreaper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wreaper",
        abstract: "Reap windowless background apps after a configured timeout.",
        version: "0.1.0",
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
