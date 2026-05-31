/// Enumerates currently-running applications. The real implementation (M5)
/// wraps `NSWorkspace.shared.runningApplications`; tests use `FakeAppEnumerator`.
///
/// Apps with a nil `CFBundleIdentifier` are dropped at this boundary — they
/// can never be tracked because rules key on bundle ID.
public protocol AppEnumerator: Sendable {
    func enumerate() async -> [RunningApp]
}
