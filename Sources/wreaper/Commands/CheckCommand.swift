import ArgumentParser
import Foundation
import WindowlessReaperCore

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run a single dry-run tick and print what would be terminated.",
        discussion: """
        Exits 0 if no apps would be terminated this tick.
        Exits 1 if at least one app is past its timeout and would be reaped.
        terminate() is never called from `check`.
        """
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let url = ConfigPath.resolve(override: globals.config)
        let config = try ConfigPath.load(from: url)
        try GlobalOptions.bootstrapLogging(globals: globals, config: config)

        try await CLIPermissions.requireAccessibility()

        let enumerator = NSWorkspaceAppEnumerator()
        let engine = ReaperEngine(
            config: config,
            enumerator: enumerator,
            inspector: AXWindowInspector(),
            terminator: NSRunningApplicationTerminator(),
            clock: SystemClock(),
            sleepWake: NoopSleepWake(),
            powerState: AlwaysVisiblePowerState()
        )

        let decisions = await engine.tick(dryRun: true)
        // Second enumeration so we can annotate decisions with per-bundle
        // launch ages. NSWorkspace.runningApplications is in-process and
        // cheap; the duplication is not worth the API gymnastics it would
        // take to thread launch-date info out of the engine.
        let now = Date()
        let newestLaunchByBundle = await Self.newestLaunchByBundle(enumerator: enumerator)
        let lines = decisions
            .map { format($0, now: now, newestLaunch: newestLaunchByBundle[bundleID(of: $0)]) }
            .sorted()
        for line in lines {
            print(line)
        }

        let wouldEvict = decisions.contains { if case .evict = $0 { true } else { false } }
        if wouldEvict {
            throw ExitCode(1)
        }
    }

    private static func newestLaunchByBundle(
        enumerator: any AppEnumerator
    ) async -> [BundleID: Date] {
        let apps = await enumerator.enumerate()
        var result: [BundleID: Date] = [:]
        for app in apps {
            guard let launch = app.launchDate else { continue }
            if let existing = result[app.bundleID], existing >= launch { continue }
            result[app.bundleID] = launch
        }
        return result
    }

    private func bundleID(of decision: Decision) -> BundleID {
        switch decision {
        case .ignore(let id), .track(let id, _), .evict(let id, _), .cooldown(let id, _):
            id
        }
    }

    private func format(_ decision: Decision, now: Date, newestLaunch: Date?) -> String {
        let ageSuffix = newestLaunch.map { " age=\(AgeFormatting.format(now.timeIntervalSince($0)))" } ?? ""
        return switch decision {
        case .ignore(let id):
            "ignore     \(id.value)\(ageSuffix)"
        case .track(let id, _):
            "candidate  \(id.value)\(ageSuffix)"
        case .evict(let id, let pids):
            "would-evict \(id.value) pids=\(pids.sorted())\(ageSuffix)"
        case .cooldown(let id, _):
            "cooldown   \(id.value)\(ageSuffix)"
        }
    }
}

/// `wreaper check` is a single-shot — power state is always visible so the
/// tick is never suppressed regardless of the host's current wake state.
private struct AlwaysVisiblePowerState: SystemPowerStateObserver {
    nonisolated func isUserVisible() -> Bool {
        true
    }

    func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
        }
    }

    func start() async {}
    func stop() async {}
}

/// `wreaper check` is a single-shot — no sleep/wake handling is meaningful.
/// `wreaper run` (M7) installs a real NSWorkspace-backed observer.
private struct NoopSleepWake: SleepWakeObserver {
    func consumeGraceTick() async -> Bool {
        false
    }

    func isAsleep() async -> Bool {
        false
    }

    func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }

    func start() async {}
    func stop() async {}
}
