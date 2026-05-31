import ArgumentParser
import Logging
import WindowlessReaperCore

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the config file.")
    var config: String?

    @Option(name: .long, help: "Log level: trace|debug|info|notice|warn|error")
    var logLevel: String?

    @Flag(name: .long, help: "Log decisions but never terminate apps.")
    var dryRun: Bool = false

    /// Single bootstrap path used by every command that emits logs. Resolves
    /// CLI override vs config and installs the LoggingSystem handler exactly
    /// once. Invalid levels surface as ValidationError before any monitoring
    /// starts.
    static func bootstrapLogging(globals: GlobalOptions, config: Config) throws {
        let level: Logger.Level
        do {
            level = try LogLevelBootstrap.resolve(
                cliOverride: globals.logLevel,
                configValue: config.settings.logLevel
            )
        } catch {
            throw ValidationError(String(describing: error))
        }
        LogLevelBootstrap.apply(level)
    }
}
