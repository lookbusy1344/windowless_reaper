import Foundation
import Testing
import WindowlessReaperCore

private func bid(_ s: String) -> BundleID {
    BundleID(s)
}

@Suite("ConfigScaffold selection", .timeLimit(.minutes(1)))
struct ConfigScaffoldSelectionTests {
    private static let safari = bid("com.apple.Safari")
    private static let dock = bid("com.apple.dock")
    private static let finder = bid("com.apple.finder")
    private static let slack = bid("com.tinyspeck.slackmacgap")
    private static let wreaper = bid(ConfigScaffold.ownBundleID)

    @Test("excludes wreaper's own bundle")
    func excludesOwnBundle() {
        let apps = [RunningApp(bundleID: Self.wreaper, pid: 100)]
        let states: [pid_t: WindowState] = [100: .none]
        let result = ConfigScaffold.selectBundles(apps: apps, windowStates: states, options: .init())
        #expect(result.isEmpty)
    }

    @Test("excludes core-system apple bundles on the denylist")
    func excludesSystemAppleBundles() {
        let apps = [
            RunningApp(bundleID: Self.dock, pid: 101),
            RunningApp(bundleID: Self.finder, pid: 102),
        ]
        let states: [pid_t: WindowState] = [101: .none, 102: .none]
        let result = ConfigScaffold.selectBundles(apps: apps, windowStates: states, options: .init())
        #expect(result.isEmpty)
    }

    @Test("includes apple user-facing apps like third-party apps")
    func includesAppleUserApps() {
        let pages = bid("com.apple.iWork.Pages")
        let terminal = bid("com.apple.Terminal")
        let apps = [
            RunningApp(bundleID: Self.safari, pid: 200),
            RunningApp(bundleID: Self.slack, pid: 201),
            RunningApp(bundleID: pages, pid: 202),
            RunningApp(bundleID: terminal, pid: 203),
        ]
        let states: [pid_t: WindowState] = [200: .none, 201: .none, 202: .none, 203: .none]
        let result = ConfigScaffold.selectBundles(apps: apps, windowStates: states, options: .init())
        #expect(result == [Self.safari, terminal, pages, Self.slack].sorted(by: { $0.value < $1.value }))
    }

    @Test("--include-system surfaces non-curated apple bundles too")
    func includeSystemFlag() {
        let apps = [RunningApp(bundleID: Self.dock, pid: 101)]
        let states: [pid_t: WindowState] = [101: .none]
        let result = ConfigScaffold.selectBundles(
            apps: apps,
            windowStates: states,
            options: .init(windowlessOnly: true, includeSystem: true)
        )
        #expect(result == [Self.dock])
    }

    @Test("windowlessOnly: drops apps with any visible window")
    func windowlessOnlyDropsVisible() {
        let apps = [RunningApp(bundleID: Self.slack, pid: 300)]
        let states: [pid_t: WindowState] = [300: .visible]
        let result = ConfigScaffold.selectBundles(apps: apps, windowStates: states, options: .init())
        #expect(result.isEmpty)
    }

    @Test("windowlessOnly: drops bundle if ANY pid has a window")
    func windowlessOnlyAllPidsMustBeNone() {
        let apps = [
            RunningApp(bundleID: Self.slack, pid: 300),
            RunningApp(bundleID: Self.slack, pid: 301),
        ]
        let states: [pid_t: WindowState] = [300: .none, 301: .minimised]
        let result = ConfigScaffold.selectBundles(apps: apps, windowStates: states, options: .init())
        #expect(result.isEmpty)
    }

    @Test("--all-running keeps visible apps")
    func allRunningKeepsVisible() {
        let apps = [RunningApp(bundleID: Self.slack, pid: 300)]
        let states: [pid_t: WindowState] = [300: .visible]
        let result = ConfigScaffold.selectBundles(
            apps: apps,
            windowStates: states,
            options: .init(windowlessOnly: false, includeSystem: false)
        )
        #expect(result == [Self.slack])
    }

    @Test("output is sorted by bundle ID")
    func outputSorted() {
        let zed = bid("zz.test.app")
        let apps = [
            RunningApp(bundleID: Self.slack, pid: 400),
            RunningApp(bundleID: zed, pid: 401),
            RunningApp(bundleID: Self.safari, pid: 402),
        ]
        let states: [pid_t: WindowState] = [400: .none, 401: .none, 402: .none]
        let result = ConfigScaffold.selectBundles(apps: apps, windowStates: states, options: .init())
        #expect(result == [Self.safari, Self.slack, zed])
    }
}

@Suite("ConfigScaffold rendering", .timeLimit(.minutes(1)))
struct ConfigScaffoldRenderTests {
    @Test("renders each bundle with timeout=\"none\"")
    func rendersNone() {
        let toml = ConfigScaffold.renderTOML(bundles: [bid("com.apple.Safari"), bid("com.tinyspeck.slackmacgap")])
        #expect(toml.contains("[apps.\"com.apple.Safari\"]"))
        #expect(toml.contains("[apps.\"com.tinyspeck.slackmacgap\"]"))
        // Every emitted timeout line is "none" — nothing reapable straight from a scaffold.
        let timeoutLines = toml.split(separator: "\n").filter { $0.contains("timeout") && !$0.hasPrefix("#") }
        #expect(!timeoutLines.isEmpty)
        for line in timeoutLines {
            #expect(line.contains("\"none\""), "expected timeout=\"none\", got: \(line)")
        }
    }

    @Test("rendered output is a valid, parseable config")
    func rendersParseable() throws {
        let toml = ConfigScaffold.renderTOML(bundles: [bid("com.apple.Safari"), bid("com.tinyspeck.slackmacgap")])
        let config = try ConfigLoader.load(toml: toml)
        #expect(config.rules.count == 2)
        for (_, rule) in config.rules {
            #expect(rule.timeout == nil)
        }
    }

    @Test("empty bundle list still yields a parseable, rule-free config")
    func rendersEmpty() throws {
        let toml = ConfigScaffold.renderTOML(bundles: [])
        let config = try ConfigLoader.load(toml: toml)
        #expect(config.rules.isEmpty)
    }
}
