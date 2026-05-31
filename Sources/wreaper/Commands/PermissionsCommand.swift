import ArgumentParser
import Darwin
import Foundation
import WindowlessReaperCore

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Check or request Accessibility permission.",
        subcommands: [CheckSubcommand.self, RequestSubcommand.self, PathSubcommand.self]
    )

    struct CheckSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Report whether this binary has Accessibility trust. Exit 0 if yes, 1 if no."
        )

        func run() async throws {
            let probe: any PermissionProbe = AccessibilityPermission()
            let trusted = await probe.isTrusted()
            let exec = Self.currentExecutablePath()
            print("binary: \(exec)")
            if trusted {
                print("accessibility: granted")
            } else {
                print("accessibility: not granted")
                print("grant by adding the binary above in System Settings → Privacy & Security → Accessibility.")
                throw ExitCode(1)
            }
        }

        static func currentExecutablePath() -> String {
            var size = UInt32(PATH_MAX)
            var buffer = [CChar](repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let bytes: [UInt8] = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let path = String(bytes: bytes, encoding: .utf8) ?? "(unparseable)"
                // Resolve symlinks so the user gets the actual path TCC will track.
                return (path as NSString).resolvingSymlinksInPath
            }
            return CommandLine.arguments.first ?? "(unknown)"
        }
    }

    struct RequestSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "request",
            abstract: "Surface the system Accessibility prompt for this binary."
        )

        func run() async throws {
            let probe: any PermissionProbe = AccessibilityPermission()
            let granted = await probe.requestTrust()
            if granted {
                print("accessibility: granted")
            } else {
                print("accessibility: prompt shown — toggle the switch in System Settings, then re-run.")
                throw ExitCode(1)
            }
        }
    }

    struct PathSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the absolute binary path that must be granted Accessibility."
        )

        func run() async throws {
            print(CheckSubcommand.currentExecutablePath())
        }
    }
}
