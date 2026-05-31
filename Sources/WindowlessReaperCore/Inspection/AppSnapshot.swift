import Foundation

public struct RunningApp: Sendable, Equatable, Hashable {
    public let bundleID: BundleID
    public let pid: pid_t
    /// Wallclock launch time as reported by `NSRunningApplication.launchDate`.
    /// `nil` when the workspace didn't witness the launch (apps adopted
    /// mid-session, certain background-policy edge cases) or in tests that
    /// don't synthesise one — callers must treat `nil` as "unknown", not
    /// "freshly launched".
    public let launchDate: Date?

    public init(bundleID: BundleID, pid: pid_t, launchDate: Date? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.launchDate = launchDate
    }
}

/// Combined inspection result for a single bundle ID: every PID currently running
/// under that bundle, with its observed window state. Produced by the engine by
/// composing `AppEnumerator` with `WindowInspector`.
public struct AppSnapshot: Equatable, Sendable {
    public let bundleID: BundleID
    public let windowStates: [pid_t: WindowState]

    public init(bundleID: BundleID, windowStates: [pid_t: WindowState]) {
        self.bundleID = bundleID
        self.windowStates = windowStates
    }

    public var pids: Set<pid_t> {
        Set(windowStates.keys)
    }

    public var hasUnknownWindows: Bool {
        windowStates.values.contains(.unknown)
    }

    /// A bundle counts as windowless only when **every** PID under it reports `.none`.
    /// If any PID has a visible or minimised window, the bundle is not a candidate.
    public var isFullyWindowless: Bool {
        guard !windowStates.isEmpty else { return false }
        return !hasUnknownWindows && windowStates.values.allSatisfy { $0 == .none }
    }
}
