import Foundation
import Testing
import WindowlessReaperCore

/// Byte-exact golden-file checks for user-visible output. Snapshots live in
/// `Tests/.../__Snapshots__/` and are bundled as test resources. To refresh
/// a snapshot after an intentional change, set `WREAPER_RECORD_SNAPSHOTS=1`
/// in the environment and re-run the affected test — the file is rewritten
/// from the live output and the test fails the first time so the diff lands
/// in source control deliberately, not silently.
@Suite("Snapshots", .timeLimit(.minutes(1)))
struct SnapshotTests {
    @Test("config show: canonical TOML output is stable")
    func configShowSnapshot() throws {
        let cfg = try ConfigLoader.load(toml: SnapshotFixtures.canonicalConfig)
        assertSnapshot(name: "config-show.toml", actual: cfg.toTOML())
    }

    @Test("config validate: error rendering for unknown settings key")
    func configValidateUnknownSettings() {
        let actual = renderConfigError(.unknownSettingsKey(key: "timeuot"))
        assertSnapshot(name: "validate-unknown-settings.txt", actual: actual)
    }

    @Test("config validate: error rendering for invalid log_level")
    func configValidateInvalidLogLevel() {
        let actual = renderConfigError(.invalidLogLevel(value: "loud"))
        assertSnapshot(name: "validate-invalid-loglevel.txt", actual: actual)
    }

    @Test("diagnose: full report rendering for a fixture config")
    func diagnoseReportSnapshot() {
        let safari = BundleID("com.apple.Safari")
        let cfg = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 180))]
        )
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: true,
            configPath: "/Users/test/.config/windowless-reaper/config.toml",
            config: cfg,
            decisions: [.ignore(safari)],
            pid: 4242,
            effectiveLogLevel: "info",
            effectiveDryRun: false,
            launchAgentPlistPath: nil,
            launchAgentInstalled: false,
            logTailPath: nil
        )
        assertSnapshot(name: "diagnose.txt", actual: report.render())
    }

    @Test("diagnose: report rendering includes the runtime-health section when present")
    func diagnoseReportWithHealthSnapshot() {
        let safari = BundleID("com.apple.Safari")
        let cfg = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 180))]
        )
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: true,
            configPath: "/Users/test/.config/windowless-reaper/config.toml",
            config: cfg,
            decisions: [.ignore(safari)],
            pid: 4242,
            effectiveLogLevel: "info",
            effectiveDryRun: false,
            launchAgentPlistPath: nil,
            launchAgentInstalled: false,
            logTailPath: nil,
            health: RuntimeHealthSnapshot(
                ticks: 1280,
                skippedAsleep: 40,
                skippedNotVisible: 312,
                skippedGrace: 6,
                skippedImplicitWake: 2,
                configUpdates: 3,
                axUnknownInspections: 17,
                checkpointSaveFailures: 0
            )
        )
        assertSnapshot(name: "diagnose-with-health.txt", actual: report.render())
    }
}

// MARK: - Helpers

enum SnapshotFixtures {
    static let canonicalConfig = """
    [settings]
    poll_interval    = "30s"
    log_level        = "info"
    dry_run          = false
    default_cooldown = "5x"

    [apps."com.apple.Safari"]
    timeout = "3m"

    [apps."com.apple.mail"]
    timeout  = "10m"
    cooldown = "20m"
    """
}

private func renderConfigError(_ error: ConfigError) -> String {
    error.userFacingMessage
}

private func assertSnapshot(name: String, actual: String) {
    let url: URL
    do {
        url = try snapshotURL(name: name)
    } catch {
        Issue.record("snapshot setup failed for \(name): \(error)")
        return
    }
    let recording = ProcessInfo.processInfo.environment["WREAPER_RECORD_SNAPSHOTS"] == "1"
    if recording || !FileManager.default.fileExists(atPath: url.path) {
        do {
            try actual.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Issue.record("failed to write snapshot \(name): \(error)")
            return
        }
        Issue.record("recorded snapshot \(name) — re-run without WREAPER_RECORD_SNAPSHOTS to verify")
        return
    }
    let expected: String
    do {
        expected = try String(contentsOf: url, encoding: .utf8)
    } catch {
        Issue.record("failed to read snapshot \(name): \(error)")
        return
    }
    if actual != expected {
        Issue.record(
            "snapshot mismatch for \(name)\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)"
        )
    }
}

private func snapshotURL(name: String) throws -> URL {
    // Tests run from the SwiftPM build directory; resources are bundled into
    // the .xctest. For recording, we want to write back into source so the
    // diff is reviewable — locate the source path from #filePath.
    let recording = ProcessInfo.processInfo.environment["WREAPER_RECORD_SNAPSHOTS"] == "1"
    if recording {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
            .appendingPathComponent(name)
    }
    guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
        // First-time bootstrap: record into the source tree.
        let here = URL(fileURLWithPath: #filePath)
        let dir = here.deletingLastPathComponent().appendingPathComponent("__Snapshots__")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    return url
}
