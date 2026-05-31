import Foundation
import Testing
import WindowlessReaperCore

@Suite("M8 — Permissions", .timeLimit(.minutes(1)))
struct M8PermissionsTests {
    /// Fake probe — full control over the trust answer in tests.
    private actor FakeProbe: PermissionProbe {
        private var trusted: Bool
        private(set) var requestCount = 0

        init(trusted: Bool) {
            self.trusted = trusted
        }

        func setTrusted(_ value: Bool) {
            trusted = value
        }

        func isTrusted() -> Bool {
            trusted
        }

        func requestTrust() -> Bool {
            requestCount += 1
            return trusted
        }
    }

    @Test("Bootstrap.requireAXTrust returns when trusted")
    func bootstrapPassesWhenTrusted() async throws {
        let probe = FakeProbe(trusted: true)
        try await Bootstrap.requireAXTrust(probe: probe)
    }

    @Test("runRefusesWithoutAXTrust: untrusted probe throws accessibilityNotGranted")
    func runRefusesWithoutAXTrust() async throws {
        let probe = FakeProbe(trusted: false)
        await #expect(throws: PermissionError.accessibilityNotGranted) {
            try await Bootstrap.requireAXTrust(probe: probe)
        }
    }

    @Test("requestTrust delegates to the probe and reports its result")
    func requestTrustDelegates() async {
        let granted = FakeProbe(trusted: true)
        #expect(await granted.requestTrust())
        #expect(await granted.requestCount == 1)

        let denied = FakeProbe(trusted: false)
        #expect(await denied.requestTrust() == false)
        #expect(await denied.requestCount == 1)
    }
}
