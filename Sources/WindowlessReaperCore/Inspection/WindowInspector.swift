import Foundation

/// Outcome of one window-state inspection.
///
/// `state` is the classification the engine acts on. `unreadableWindows`
/// counts windows whose per-window attributes (e.g. `kAXMinimizedAttribute`)
/// could not be read during this inspection. Such a read failure does *not*
/// change `state` — the inspector falls back to "treat as not minimised" so it
/// never wrongly evicts — but the count is surfaced so the blind spot is
/// observable in runtime-health instead of vanishing silently.
public struct WindowInspection: Sendable, Equatable {
    public let state: WindowState
    public let unreadableWindows: Int

    public init(state: WindowState, unreadableWindows: Int = 0) {
        self.state = state
        self.unreadableWindows = unreadableWindows
    }
}

/// Reports the window state of a process. The real implementation (M5)
/// queries `kAXWindowsAttribute` via the Accessibility API.
public protocol WindowInspector: Sendable {
    func inspect(pid: pid_t) async -> WindowInspection
}
