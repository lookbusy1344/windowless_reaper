import ApplicationServices
import Foundation

/// Real `PermissionProbe` backed by `AXIsProcessTrustedWithOptions`. This is
/// the only file in the project that touches the AX trust API — every other
/// caller goes through `PermissionProbe` so tests can fake the answer.
public struct AccessibilityPermission: PermissionProbe {
    public init() {}

    public func isTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    public func requestTrust() -> Bool {
        // The constant `kAXTrustedCheckOptionPrompt` is a CFStringRef imported
        // as a mutable global, which Swift 6 strict-concurrency rejects.
        // The documented value of that constant is the literal below; using
        // it directly is the established workaround.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
