import ArgumentParser
import WindowlessReaperCore

enum CLIPermissions {
    static func requireAccessibility() async throws {
        do {
            try await Bootstrap.requireAXTrust(probe: AccessibilityPermission())
        } catch PermissionError.accessibilityNotGranted {
            throw ValidationError(
                "Accessibility permission not granted. Run 'wreaper permissions request' or grant it in System Settings → Privacy & Security → Accessibility."
            )
        }
    }
}
