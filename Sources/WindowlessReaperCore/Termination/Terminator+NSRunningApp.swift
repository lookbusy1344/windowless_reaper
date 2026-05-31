import AppKit
import Foundation

/// Real `Terminator` backed by `NSRunningApplication.terminate()`.
///
/// Polite termination only — `forceTerminate()` is never invoked.
///
/// Per the `NSRunningApplication.terminate()` contract, the return value
/// reflects whether the quit request was *delivered*, not whether the app
/// actually quit: it returns `true` when the request was successfully sent —
/// **including** when the app responds by surfacing an unsaved-work dialog —
/// and `false` only when the app is already gone or has no GUI. A `nil` lookup
/// (PID gone between enumeration and termination) likewise returns `false`.
///
/// So a returned `false` means "not delivered (pid vanished)", not "vetoed".
/// A genuine veto returns `true`; the engine handles it on the next tick,
/// where the unsaved-work dialog reads as a window (the app is no longer
/// windowless) and the already-staged cooldown holds.
public struct NSRunningApplicationTerminator: Terminator {
    public init() {}

    public func terminate(pid: pid_t) async -> Bool {
        await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.terminate()
        }
    }
}
