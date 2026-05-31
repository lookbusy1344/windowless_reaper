import AppKit
import Foundation

/// Real `AppEnumerator` backed by `NSWorkspace.shared.runningApplications`.
///
/// Filters to `.regular` activation policy — these are the GUI apps a user
/// would consider "open". Background-only and accessory apps are excluded so
/// the reaper never targets daemons or menu-bar utilities.
///
/// Apps with a nil `CFBundleIdentifier` are dropped at this boundary. Rules
/// key on bundle ID; an app without one can never match a rule, so it would
/// only add noise to downstream stages.
///
/// `NSWorkspace` and `NSRunningApplication` are MainActor-isolated in the
/// Swift 6 SDK overlay, so we hop to the main actor for the read. The result
/// is a `Sendable` array of value types — nothing AppKit-flavoured escapes.
public struct NSWorkspaceAppEnumerator: AppEnumerator {
    public init() {}

    public func enumerate() async -> [RunningApp] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
                guard app.activationPolicy == .regular,
                      let raw = app.bundleIdentifier
                else {
                    return nil
                }
                let bundleID = BundleID(raw)
                return RunningApp(
                    bundleID: bundleID,
                    pid: app.processIdentifier,
                    launchDate: app.launchDate
                )
            }
        }
    }
}
