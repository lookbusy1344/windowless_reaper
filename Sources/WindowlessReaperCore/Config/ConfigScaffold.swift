import Foundation

/// Builds a starter config from the set of currently-running, windowless apps.
///
/// The scaffold is *safe by default*: every emitted rule has `timeout = "none"`
/// so a freshly scaffolded config reaps nothing. The user flips entries to a
/// real duration to activate them.
///
/// Core macOS system bundles (Dock, Finder, etc.) are filtered out by default
/// because terminating them would degrade the session. Every other Apple app
/// — iWork, Terminal, Music, Mail, Safari, etc. — is a reaping candidate
/// like any third-party app, since `AppEnumerator` already restricts to
/// `.regular` activation policy and so weeds out background daemons.
public enum ConfigScaffold {
    /// Core macOS bundles that are GUI-visible (`.regular` activation) but
    /// not safe to terminate — quitting them degrades or breaks the session.
    /// Everything else under `com.apple.*` is treated as a normal candidate.
    public static let appleSystemDenylist: Set<String> = [
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
    ]

    /// Bundle ID of wreaper itself — always excluded from scaffold output.
    public static let ownBundleID = "com.github.lookbusy1344.windowless-reaper"

    public struct Options: Sendable {
        /// When true, emit only apps whose windows are all `.none`. When
        /// false, emit every running candidate regardless of window state.
        public let windowlessOnly: Bool
        /// When true, also surface core-system bundles like Dock and Finder.
        /// Off by default — those entries would never be safe to reap.
        public let includeSystem: Bool

        public init(windowlessOnly: Bool = true, includeSystem: Bool = false) {
            self.windowlessOnly = windowlessOnly
            self.includeSystem = includeSystem
        }
    }

    /// Compute the set of bundle IDs to include in the scaffold. Pure — no
    /// I/O. `apps` and `windowStates` are the engine's own observations of
    /// the running session.
    public static func selectBundles(
        apps: [RunningApp],
        windowStates: [pid_t: WindowState],
        options: Options
    ) -> [BundleID] {
        let grouped = Dictionary(grouping: apps, by: { $0.bundleID })
        var selected: [BundleID] = []
        for (bundleID, runningApps) in grouped {
            if bundleID.value == ownBundleID { continue }
            if isFilteredAppleSystem(bundleID, includeSystem: options.includeSystem) { continue }
            if options.windowlessOnly {
                let allWindowless = runningApps.allSatisfy { windowStates[$0.pid] == WindowState.none }
                if !allWindowless { continue }
            }
            selected.append(bundleID)
        }
        return selected.sorted(by: { $0.value < $1.value })
    }

    private static func isFilteredAppleSystem(_ bundleID: BundleID, includeSystem: Bool) -> Bool {
        guard !includeSystem else { return false }
        return appleSystemDenylist.contains(bundleID.value)
    }

    /// Render a TOML body listing the given bundles, all with `timeout = "none"`.
    /// Includes a leading comment block explaining how to activate entries.
    public static func renderTOML(bundles: [BundleID]) -> String {
        var out = """
        # Scaffold generated from currently-running apps.
        # Every entry below is inert (timeout = "none"). Replace "none" with a
        # duration like "10m" to start reaping that app once it has been
        # windowless for that long.

        """
        if bundles.isEmpty {
            out += "\n# (no candidate apps detected)\n"
            return out
        }
        for bundleID in bundles {
            out += "\n[apps.\"\(bundleID.value)\"]\n"
            out += "timeout = \"none\"\n"
        }
        return out
    }
}
