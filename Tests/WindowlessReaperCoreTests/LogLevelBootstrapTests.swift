import Logging
import Testing
import WindowlessReaperCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LogLevelBootstrapTests {
    @Test("parse accepts known levels", arguments: [
        ("trace", Logger.Level.trace),
        ("debug", .debug),
        ("info", .info),
        ("notice", .notice),
        ("warn", .warning),
        ("warning", .warning),
        ("error", .error),
    ])
    func parseAcceptsKnownLevels(input: String, expected: Logger.Level) throws {
        #expect(try LogLevelBootstrap.parse(input) == expected)
    }

    @Test("parse rejects unknown levels")
    func parseRejectsUnknown() {
        #expect(throws: (any Error).self) { try LogLevelBootstrap.parse("loud") }
    }

    @Test("resolve: CLI override beats config value")
    func cliOverrideBeatsConfig() throws {
        let level = try LogLevelBootstrap.resolve(cliOverride: "debug", configValue: "error")
        #expect(level == .debug)
    }

    @Test("resolve: falls back to config when no CLI override")
    func fallsBackToConfig() throws {
        let level = try LogLevelBootstrap.resolve(cliOverride: nil, configValue: "warning")
        #expect(level == .warning)
    }

    @Test("resolve: invalid CLI override throws")
    func invalidCLI() {
        #expect(throws: (any Error).self) {
            _ = try LogLevelBootstrap.resolve(cliOverride: "loud", configValue: "info")
        }
    }

    @Test("apply installs handler factory and updates currentLevel")
    func applyUpdatesLevel() {
        LogLevelBootstrap.apply(.debug)
        #expect(LogLevelBootstrap.currentLevel == .debug)
        // Logger construction must exercise the installed factory.
        let logger = Logger(label: "wreaper.test.bootstrap")
        _ = logger // silence unused-let; construction is the assertion
        LogLevelBootstrap.apply(.warning)
        #expect(LogLevelBootstrap.currentLevel == .warning)
        // Restore a sensible default for any subsequent tests.
        LogLevelBootstrap.apply(.info)
    }

    @Test("apply changes effective level for already-constructed loggers")
    func appliesToExistingLoggers() {
        LogLevelBootstrap.apply(.info)
        let logger = Logger(label: "wreaper.test.hot-reload")
        #expect(logger.logLevel == .info)
        LogLevelBootstrap.apply(.debug)
        #expect(logger.logLevel == .debug, "hot reload must affect existing handlers")
        LogLevelBootstrap.apply(.error)
        #expect(logger.logLevel == .error)
        LogLevelBootstrap.apply(.info)
    }
}
