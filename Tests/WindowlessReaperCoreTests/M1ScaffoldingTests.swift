import Foundation
import Testing

@Suite("M1 Scaffolding", .timeLimit(.minutes(1)))
struct M1ScaffoldingTests {
    @Test("help output lists all documented subcommands")
    func helpListsAllSubcommands() async throws {
        let binary = TestProcessRunner.product(named: "wreaper")
        let result = try await TestProcessRunner.runExpectingSuccess(binary: binary, arguments: ["--help"])

        let expected = ["run", "check", "clear", "status", "permissions", "install", "uninstall", "config", "diagnose"]
        for subcommand in expected {
            #expect(result.combinedOutput.contains(subcommand), "Missing subcommand '\(subcommand)' in --help output")
        }
    }
}
