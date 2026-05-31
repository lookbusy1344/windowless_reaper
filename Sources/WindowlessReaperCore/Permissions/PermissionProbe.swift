/// Seam for Accessibility-trust queries. Behind a protocol so tests can drive
/// the trust answer without touching the real TCC database (which is
/// SIP-protected and cannot be scripted on macOS).
///
/// The single real implementation is `AccessibilityPermission`, which wraps
/// `AXIsProcessTrustedWithOptions`.
public protocol PermissionProbe: Sendable {
    /// Quiet check — never prompts. Equivalent to `AXIsProcessTrustedWithOptions(nil)`.
    func isTrusted() async -> Bool

    /// Surfaces the system Accessibility prompt and returns the resulting
    /// trust state. The dialog is asynchronous — a `false` return here does
    /// not mean the grant was refused, only that it has not been granted yet.
    func requestTrust() async -> Bool
}

public enum PermissionError: Error, Equatable {
    case accessibilityNotGranted
}

public enum Bootstrap {
    /// Refuse to proceed if Accessibility is not granted. `wreaper run` calls
    /// this before constructing the engine — without AX trust, the AX-backed
    /// `WindowInspector` returns `.none` for every PID and the engine would
    /// happily reap everything in the allowlist.
    public static func requireAXTrust(probe: any PermissionProbe) async throws {
        guard await probe.isTrusted() else {
            throw PermissionError.accessibilityNotGranted
        }
    }
}
