import ArgumentParser
import Foundation
import WindowlessReaperCore

struct ClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Politely terminate every allowlisted app that is currently windowless.",
        discussion: """
        Like `check`, but instead of waiting for the per-app timeout, every
        allowlisted bundle that is fully windowless right now is terminated
        in a single pass. Rules with `timeout = "none"` are skipped — they
        are allowlisted but not actively monitored.

        Bundles whose newest PID launched within `[settings].clear_cooldown`
        (default 30s) are left alone. PIDs whose launch date is unknown are
        treated as old enough to reap.

        Runs without prompts so it is safe to invoke from scripts. `--dry-run`
        is honoured: when set, decisions are printed and nothing is killed.

        Exits 0 once the pass completes (regardless of how many apps were
        reaped or vetoed).
        """
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let url = ConfigPath.resolve(override: globals.config)
        let config = try ConfigPath.load(from: url)
        try GlobalOptions.bootstrapLogging(globals: globals, config: config)

        try await CLIPermissions.requireAccessibility()

        let enumerator = NSWorkspaceAppEnumerator()
        let inspector = AXWindowInspector()
        let terminator = NSRunningApplicationTerminator()

        let candidates = await buildAllowlistedCandidates(
            enumerator: enumerator,
            inspector: inspector,
            rules: config.rules
        )

        let effectiveDryRun = globals.dryRun || config.settings.dryRun
        let now = Date()
        let cooldown = TimeInterval(config.settings.clearCooldown.seconds)

        for candidate in candidates.sorted(by: { $0.snapshot.bundleID.value < $1.snapshot.bundleID.value }) {
            let bundle = candidate.snapshot.bundleID.value
            let ageSuffix = candidate.newestLaunch.map { " age=\(AgeFormatting.format(now.timeIntervalSince($0)))" } ?? ""

            guard candidate.snapshot.isFullyWindowless else {
                print("skip       \(bundle) has-window\(ageSuffix)")
                continue
            }
            if let launch = candidate.newestLaunch, now.timeIntervalSince(launch) < cooldown {
                print("skip       \(bundle) just-launched\(ageSuffix)")
                continue
            }
            let pids = candidate.snapshot.pids.sorted()
            if effectiveDryRun {
                print("would-evict \(bundle) pids=\(pids)\(ageSuffix)")
                continue
            }
            var allAccepted = true
            for pid in pids where await !(terminator.terminate(pid: pid)) {
                allAccepted = false
            }
            if allAccepted {
                print("terminated \(bundle) pids=\(pids)\(ageSuffix)")
            } else {
                print("vetoed     \(bundle) pids=\(pids)\(ageSuffix)")
            }
        }
    }

    private struct Candidate {
        let snapshot: AppSnapshot
        /// Most recent (largest) launch date across the bundle's PIDs.
        /// `nil` if no PID has a known launch date.
        let newestLaunch: Date?
    }

    private func buildAllowlistedCandidates(
        enumerator: any AppEnumerator,
        inspector: any WindowInspector,
        rules: [BundleID: Rule]
    ) async -> [Candidate] {
        let apps = await enumerator.enumerate()
        let grouped = Dictionary(grouping: apps, by: { $0.bundleID })
        var candidates: [Candidate] = []
        candidates.reserveCapacity(grouped.count)
        for (bundleID, runningApps) in grouped {
            guard let rule = rules[bundleID], rule.timeout != nil else { continue }
            var states: [pid_t: WindowState] = [:]
            for app in runningApps {
                states[app.pid] = await inspector.windowState(for: app.pid)
            }
            let newestLaunch = runningApps.compactMap(\.launchDate).max()
            candidates.append(Candidate(
                snapshot: AppSnapshot(bundleID: bundleID, windowStates: states),
                newestLaunch: newestLaunch
            ))
        }
        return candidates
    }
}
