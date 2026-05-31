@preconcurrency import AppKit
import Foundation

/// Wake- and sleep-time notification subscriptions. Kept out of the main
/// engine file to stay under the swiftlint file-length limit, and so the
/// two side-effecting subscriptions (checkpoint flush, AX trust re-check)
/// are reviewable together.
extension ReaperEngine {
    /// Subscribe to `willSleepNotification` on a detached task. Each
    /// willSleep arrival triggers `flushCheckpoint(reason:)` so per-bundle
    /// elapsed time survives a sleep-time daemon crash. macOS gives
    /// several seconds between willSleep and the actual transition —
    /// plenty for one atomic JSON write. Returns nil when no checkpointer
    /// is configured.
    static func startCheckpointOnSleep(engine: ReaperEngine) -> Task<Void, Never>? {
        let stream = NSWorkspace.shared.notificationCenter.notifications(
            named: NSWorkspace.willSleepNotification
        )
        return Task { [weak engine] in
            for await _ in stream {
                await engine?.flushCheckpoint(reason: "willSleep")
            }
        }
    }

    /// Subscribe to `didWakeNotification` on a detached task — every wake
    /// re-queries `AXIsProcessTrustedWithOptions`. The common cause of
    /// revocation during sleep is a Homebrew upgrade replacing the signed
    /// binary while the daemon was idle; without this hook the next
    /// eviction silently fails and the user has no log line explaining
    /// why. Per power_man_best_practices.md §4.15.
    static func startAXTrustCheckOnWake(
        engine: ReaperEngine,
        probe: (any PermissionProbe)?
    ) -> Task<Void, Never>? {
        guard let probe else { return nil }
        let stream = NSWorkspace.shared.notificationCenter.notifications(
            named: NSWorkspace.didWakeNotification
        )
        return Task { [weak engine] in
            for await _ in stream {
                let trusted = await probe.isTrusted()
                await engine?.updateAccessibilityRevoked(!trusted)
            }
        }
    }
}
