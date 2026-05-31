import Foundation
import IOKit
import Testing
@testable import WindowlessReaperCore

@Suite("Observer lifecycle idempotence", .timeLimit(.minutes(1)))
struct ObserverLifecycleIdempotenceTests {
    @Test("SystemPowerPressure.start() is idempotent")
    func systemPowerPressureStartIsIdempotent() async {
        let observer = SystemPowerPressure()

        await observer.start()
        #expect(observer.activeTokenCount == 2)

        await observer.start()
        #expect(observer.activeTokenCount == 2)

        await observer.stop()
        #expect(observer.activeTokenCount == 0)
    }

    @Test("NSWorkspaceScreenWake.start() is idempotent")
    func nsWorkspaceScreenWakeStartIsIdempotent() async {
        let observer = NSWorkspaceScreenWake()

        await observer.start()
        #expect(observer.activeTokenCount == 2)

        await observer.start()
        #expect(observer.activeTokenCount == 2)

        await observer.stop()
        #expect(observer.activeTokenCount == 0)
    }

    @Test("IOKitSleepWake.start() is idempotent")
    func iokitSleepWakeStartIsIdempotent() async {
        let registrar = RecordingIOKitRegistrar()
        let observer = IOKitSleepWake(registrar: registrar)

        await observer.start()
        #expect(registrar.registerCallCount == 1)
        #expect(observer.isRegistered)

        await observer.start()
        #expect(registrar.registerCallCount == 1)

        await observer.stop()
        #expect(registrar.deregisterCallCount == 1)
        #expect(!observer.isRegistered)
    }
}

private final class RecordingIOKitRegistrar: IOKitSystemPowerRegistering, @unchecked Sendable {
    private(set) var registerCallCount = 0
    private(set) var deregisterCallCount = 0

    func register(
        refcon _: UnsafeMutableRawPointer,
        callback _: IOServiceInterestCallback,
        notifier: inout io_object_t
    ) -> IOKitSystemPowerRegistration? {
        registerCallCount += 1
        notifier = 42
        return IOKitSystemPowerRegistration(
            rootPort: 7,
            notifier: 42,
            notificationPort: nil
        )
    }

    func deregister(_ registration: IOKitSystemPowerRegistration) {
        deregisterCallCount += 1
        _ = registration
    }
}
