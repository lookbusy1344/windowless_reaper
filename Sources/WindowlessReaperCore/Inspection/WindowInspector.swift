import Foundation

/// Reports the window state of a process. The real implementation (M5)
/// queries `kAXWindowsAttribute` via the Accessibility API.
public protocol WindowInspector: Sendable {
    func windowState(for pid: pid_t) async -> WindowState
}
