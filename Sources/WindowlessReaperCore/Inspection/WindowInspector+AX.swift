import ApplicationServices
import Foundation
import Logging

/// Real `WindowInspector` backed by the Accessibility API.
///
/// Reads `kAXWindowsAttribute` on an `AXUIElement` created for the target PID
/// and classifies the result:
///
///   - No accessible windows → `.none`
///   - AX failures / timeouts / permission denial → `.unknown`
///   - Every window has `kAXMinimizedAttribute == true` → `.minimised`
///   - At least one non-minimised window exists → `.visible`
///
/// Permission-denied and other AX failures are normalised to `.unknown`.
/// The engine (via `StateTracker`) pauses eviction decisions for bundles in
/// `.unknown` state — it does not treat an un-granted or unresponsive target
/// as genuinely windowless. This is safer than `.none` because it prevents
/// accidental eviction when window state cannot be reliably observed. The
/// allowlist + `wreaper permissions check` remain the supervisory layer for
/// trust state; each tick re-tries the AX query, so granting permission later
/// is picked up without a restart.
///
/// Hang guard: every AX element gets a messaging timeout so a wedged target
/// app cannot stall the engine's tick indefinitely. On timeout the call
/// returns `.cannotComplete` and we fall through to `.unknown`, which keeps
/// the engine from treating an unresponsive target as genuinely windowless;
/// the next tick retries with a fresh element.
public struct AXWindowInspector: WindowInspector {
    /// Per-AX-call timeout. The default poll interval is 30s, so 2s leaves
    /// 15x headroom while bounding the worst case if a target's AX server
    /// is wedged.
    static let axMessagingTimeoutSeconds: Float = 2.0

    private let logger: Logger

    public init(logger: Logger = Logger(label: "wreaper.ax")) {
        self.logger = logger
    }

    public func windowState(for pid: pid_t) async -> WindowState {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeoutSeconds)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw)

        if status == .cannotComplete {
            logger.warning("AX windows query timed out pid=\(pid)")
            return .unknown
        }
        guard status == .success, let windows = raw as? [AXUIElement] else {
            logger.warning("AX windows query failed pid=\(pid) status=\(status)")
            return .unknown
        }
        guard !windows.isEmpty else {
            return .none
        }

        var sawVisible = false
        var sawMinimised = false
        for window in windows {
            AXUIElementSetMessagingTimeout(window, Self.axMessagingTimeoutSeconds)
            if isMinimised(window, pid: pid) {
                sawMinimised = true
            } else {
                sawVisible = true
            }
        }

        if sawVisible { return .visible }
        if sawMinimised { return .minimised }
        return .none
    }

    private func isMinimised(_ window: AXUIElement, pid: pid_t) -> Bool {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &raw)
        if status == .cannotComplete {
            logger.warning("AX minimised query timed out pid=\(pid)")
            return false
        }
        guard status == .success, let value = raw as? Bool else {
            logger.warning("AX minimised query failed pid=\(pid) status=\(status)")
            return false
        }
        return value
    }
}
