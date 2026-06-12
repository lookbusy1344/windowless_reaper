import ArgumentParser
import Foundation
import WindowlessReaperCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print the current AX window classification for all regular apps."
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let probe: any PermissionProbe = AccessibilityPermission()
        let trusted = await probe.isTrusted()
        if !trusted {
            // AX calls still answer, but failures are reported as `.unknown`
            // — flag the degraded state so the output is not interpreted as
            // ground truth.
            print("# accessibility: not granted — window states will all read as 'unknown'.")
            print("# grant via 'wreaper permissions request' or System Settings.")
        }

        let enumerator = NSWorkspaceAppEnumerator()
        let inspector = AXWindowInspector()

        let apps = await enumerator.enumerate()

        // Per-app inspection in sequence — AX calls are fast and a typical
        // session has tens of apps, not thousands. Serial keeps output
        // deterministic and AX usage gentle.
        var rows: [StatusRow] = []
        rows.reserveCapacity(apps.count)
        for app in apps {
            let state = await inspector.inspect(pid: app.pid).state
            rows.append(StatusRow(bundle: app.bundleID.value, pid: app.pid, state: state))
        }

        rows.sort { lhs, rhs in
            if lhs.bundle != rhs.bundle { return lhs.bundle < rhs.bundle }
            return lhs.pid < rhs.pid
        }

        for row in rows {
            print("\(row.bundle)\tpid=\(row.pid)\tstate=\(row.state)")
        }
    }
}

private struct StatusRow {
    let bundle: String
    let pid: pid_t
    let state: WindowState
}
