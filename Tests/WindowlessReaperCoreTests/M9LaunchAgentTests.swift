import Foundation
import Testing
import WindowlessReaperCore

@Suite("M9 — LaunchAgent install + diagnose", .timeLimit(.minutes(1)))
struct M9LaunchAgentTests {
    // MARK: - Install path resolution

    @Test("resolvesHomebrewPrefix: explicit prefix wins over env, env wins over /usr/local")
    func resolvesHomebrewPrefix() {
        // 1. Explicit --prefix takes precedence over everything.
        #expect(
            InstallPathResolver.resolve(prefix: "/opt/custom", homebrewPrefix: "/opt/homebrew")
                == "/opt/custom/bin/wreaper"
        )

        // 2. HOMEBREW_PREFIX env wins when no --prefix.
        #expect(
            InstallPathResolver.resolve(prefix: nil, homebrewPrefix: "/opt/homebrew")
                == "/opt/homebrew/bin/wreaper"
        )

        // 3. Falls back to /usr/local when neither set.
        #expect(
            InstallPathResolver.resolve(prefix: nil, homebrewPrefix: nil)
                == "/usr/local/bin/wreaper"
        )

        // 4. Empty HOMEBREW_PREFIX treated as unset.
        #expect(
            InstallPathResolver.resolve(prefix: nil, homebrewPrefix: "")
                == "/usr/local/bin/wreaper"
        )
    }

    @Test("user path resolution is derived from an injected home directory")
    func userPathsUseInjectedHomeDirectory() {
        let paths = UserPaths(homeDirectory: URL(fileURLWithPath: "/Users/test & friends"))
        #expect(paths.configURL.path == "/Users/test & friends/.config/windowless-reaper/config.toml")
        #expect(
            paths.launchAgentPlistURL(label: "com.user.windowless-reaper").path
                == "/Users/test & friends/Library/LaunchAgents/com.user.windowless-reaper.plist"
        )
        #expect(
            paths.logURL(relativePath: LaunchAgentPlist.logRelativePath).path
                == "/Users/test & friends/\(LaunchAgentPlist.logRelativePath)"
        )
    }

    // MARK: - Plist generation

    @Test("generatesValidPlist: contains label, program args, run-at-load, keep-alive, log paths")
    func generatesValidPlist() {
        let xml = LaunchAgentPlist.render(
            binaryPath: "/opt/homebrew/Applications/wreaper & co/bin/wreaper",
            home: "/Users/test & friends"
        )

        #expect(xml.contains("<key>Label</key>"))
        #expect(xml.contains("<string>com.user.windowless-reaper</string>"))
        #expect(xml.contains("<key>ProgramArguments</key>"))
        #expect(xml.contains("<string>/opt/homebrew/Applications/wreaper &amp; co/bin/wreaper</string>"))
        #expect(xml.contains("<string>run</string>"))
        #expect(xml.contains("<key>RunAtLoad</key>"))
        #expect(xml.contains("<true/>"))
        #expect(xml.contains("<key>KeepAlive</key>"))
        #expect(xml.contains("<key>StandardOutPath</key>"))
        #expect(xml.contains("<string>/dev/null</string>"))
        #expect(xml.contains("<key>StandardErrorPath</key>"))
        #expect(!xml.contains("windowless-reaper.stderr.log"))
        #expect(!xml.contains("/Library/Logs/windowless-reaper.log<"))

        // Must be parseable property-list XML.
        guard let data = xml.data(using: .utf8) else {
            Issue.record("plist could not be encoded as UTF-8")
            return
        }
        let parser = XMLParser(data: data)
        #expect(parser.parse(), "plist XML should parse cleanly")
    }

    // MARK: - Installer end-to-end with a faked launchctl

    private actor FakeLaunchctl: LaunchctlClient {
        private(set) var bootstrapCalls: [(plistPath: String, uid: uid_t)] = []
        private(set) var bootoutCalls: [(plistPath: String, uid: uid_t)] = []

        func bootstrap(plistPath: String, uid: uid_t) {
            bootstrapCalls.append((plistPath, uid))
        }

        func bootout(plistPath: String, uid: uid_t) {
            bootoutCalls.append((plistPath, uid))
        }
    }

    /// A real executable on disk; the new installer refuses non-executable
    /// binaries to avoid stranding a broken plist under launchd.
    private static let realExecutable = "/bin/echo"

    @Test("install writes the plist and bootstraps launchctl; uninstall reverses")
    func installAndUninstallRoundTrip() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-m9")
        defer { tmp.cleanup() }

        let plistURL = tmp.child("com.user.windowless-reaper.plist")
        let launchctl = FakeLaunchctl()
        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: Self.realExecutable,
            home: "/Users/test",
            launchctl: launchctl
        )

        try await installer.install(uid: 501)
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        #expect(await launchctl.bootstrapCalls.count == 1)
        #expect(await launchctl.bootstrapCalls.first?.uid == 501)

        try await installer.uninstall(uid: 501)
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(await launchctl.bootoutCalls.count == 1)
    }

    @Test("install refuses to clobber an existing plist without --force")
    func installRefusesClobber() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-m9")
        defer { tmp.cleanup() }

        let plistURL = tmp.child("com.user.windowless-reaper.plist")
        try "existing".write(to: plistURL, atomically: true, encoding: .utf8)

        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: Self.realExecutable,
            home: "/Users/test",
            launchctl: FakeLaunchctl()
        )

        await #expect(throws: InstallError.self) {
            try await installer.install(uid: 501)
        }
        // --force replaces in place.
        try await installer.install(uid: 501, force: true)
        let rewritten = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(rewritten != "existing")
    }

    @Test("install refuses non-executable binaries")
    func installRefusesNonExecutable() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-m9")
        defer { tmp.cleanup() }

        let plistURL = tmp.child("com.user.windowless-reaper.plist")
        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: "/this/does/not/exist/wreaper",
            home: "/Users/test",
            launchctl: FakeLaunchctl()
        )
        await #expect(throws: InstallError.self) {
            try await installer.install(uid: 501)
        }
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    }

    @Test("uninstall is idempotent when nothing is installed")
    func uninstallIdempotent() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-m9")
        defer { tmp.cleanup() }

        let plistURL = tmp.child("com.user.windowless-reaper.plist")
        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: "",
            home: "/Users/test",
            launchctl: NotLoadedLaunchctl()
        )
        // Bootout reports "not loaded" — must not be treated as failure.
        try await installer.uninstall(uid: 501)
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    }

    private actor NotLoadedLaunchctl: LaunchctlClient {
        func bootstrap(plistPath _: String, uid _: uid_t) throws {}
        func bootout(plistPath: String, uid _: uid_t) throws {
            throw LaunchctlError.nonZeroExit(
                command: "launchctl bootout",
                status: 113,
                output: "Could not find specified service: \(plistPath)"
            )
        }
    }

    @Test("renderPlanSummary lists fs + launchctl actions and quotes paths verbatim")
    func renderPlanSummary() {
        let plistURL = URL(fileURLWithPath: "/Users/a person/Library/LaunchAgents/com.user.windowless-reaper.plist")
        let installer = LaunchAgentInstaller(
            plistURL: plistURL,
            binaryPath: "/opt/homebrew/bin/wreaper",
            home: "/Users/a person",
            launchctl: FakeLaunchctl()
        )
        let summary = installer.renderPlanSummary(uid: 501)
        #expect(summary.contains("[install actions]"))
        #expect(summary.contains("[uninstall actions]"))
        #expect(summary.contains("launchctl bootstrap gui/501"))
        #expect(summary.contains("launchctl bootout gui/501"))
        // Paths with spaces survive verbatim — caller is expected to quote.
        #expect(summary.contains("/Users/a person/Library/LaunchAgents/"))
    }

    // MARK: - Decision ring

    @Test("DecisionRing keeps only the last N decisions")
    func decisionRingBounded() async {
        let ring = DecisionRing(capacity: 3)
        let id = BundleID("com.apple.Safari")
        for _ in 0 ..< 5 {
            await ring.record(.ignore(id))
        }
        let snap = await ring.snapshot()
        #expect(snap.count == 3)
    }

    // MARK: - Diagnose report

    @Test("diagnoseEmitsAllSections: version, AX trust, config path, decisions, pid")
    func diagnoseEmitsAllSections() {
        let safari = BundleID("com.apple.Safari")
        let config = Config(
            settings: Settings.defaults,
            rules: [safari: Rule(timeout: Duration(seconds: 60))]
        )
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: true,
            configPath: "/Users/test/.config/windowless-reaper/config.toml",
            config: config,
            decisions: [.ignore(safari)],
            pid: 4242
        )

        let text = report.render()
        #expect(text.contains("version: 0.1.0"))
        #expect(text.contains("accessibility: granted"))
        #expect(text.contains("config: /Users/test/.config/windowless-reaper/config.toml"))
        #expect(text.contains("pid: 4242"))
        #expect(text.contains("com.apple.Safari"))
        // Section headers exist
        #expect(text.contains("[version]"))
        #expect(text.contains("[accessibility]"))
        #expect(text.contains("[config]"))
        #expect(text.contains("[recent-decisions]"))
    }

    @Test("diagnose: untrusted AX renders as 'not granted'")
    func diagnoseUntrusted() {
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: false,
            configPath: "/dev/null",
            config: nil,
            decisions: [],
            pid: 1
        )
        #expect(report.render().contains("accessibility: not granted"))
    }

    @Test("diagnose: effective sections render log level and dry-run")
    func diagnoseEffective() {
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: true,
            configPath: "/tmp/cfg.toml",
            config: nil,
            decisions: [],
            pid: 7,
            effectiveLogLevel: "debug",
            effectiveDryRun: true,
            launchAgentPlistPath: "/Users/x/Library/LaunchAgents/com.user.windowless-reaper.plist",
            launchAgentInstalled: true,
            logTailPath: "/Users/x/Library/Logs/windowless-reaper.log"
        )
        let text = report.render()
        #expect(text.contains("[effective]"))
        #expect(text.contains("log_level: debug"))
        #expect(text.contains("dry_run: true"))
        #expect(text.contains("[launchagent]"))
        #expect(text.contains("installed: true"))
        #expect(text.contains("com.user.windowless-reaper.plist"))
        #expect(text.contains("windowless-reaper.log"))
    }

    @Test("diagnose: failed config load surfaces error string")
    func diagnoseConfigError() {
        let report = DiagnoseReport(
            version: "0.1.0",
            axTrusted: false,
            configPath: "/missing/config.toml",
            config: nil,
            configError: "fileNotFound(/missing/config.toml)",
            decisions: [],
            pid: 1
        )
        #expect(report.render().contains("config: (failed to load) fileNotFound"))
    }
}
