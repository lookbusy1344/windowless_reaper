import Foundation

/// Politely quits a process. Implementations must never force-terminate.
/// Returns `true` if `NSRunningApplication.terminate()` accepted the request
/// (note: termination itself is asynchronous; a `true` here does not mean the
/// app has exited yet). Returns `false` if the app vetoed (e.g. unsaved-work
/// dialog).
public protocol Terminator: Sendable {
    func terminate(pid: pid_t) async -> Bool
}
