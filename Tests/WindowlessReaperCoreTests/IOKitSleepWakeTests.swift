import Testing
@testable import WindowlessReaperCore

@Suite("IOKitPowerMessage.decode", .timeLimit(.minutes(1)))
struct IOKitPowerMessageDecodeTests {
    @Test("canSystemSleep maps from the published raw value")
    func canSystemSleep() {
        #expect(IOKitPowerMessage.decode(rawType: IOKitPowerMessage.canSystemSleepRawValue) == .canSystemSleep)
    }

    @Test("willSleep maps from the published raw value")
    func willSleep() {
        #expect(IOKitPowerMessage.decode(rawType: IOKitPowerMessage.willSleepRawValue) == .willSleep)
    }

    @Test("willPowerOn maps from the published raw value")
    func willPowerOn() {
        // Regression cover for the missed-wake bug: pre-fix, willPowerOn
        // was silently ignored on dark-wake paths.
        #expect(IOKitPowerMessage.decode(rawType: IOKitPowerMessage.willPowerOnRawValue) == .willPowerOn)
    }

    @Test("hasPoweredOn maps from the published raw value")
    func hasPoweredOn() {
        #expect(IOKitPowerMessage.decode(rawType: IOKitPowerMessage.hasPoweredOnRawValue) == .hasPoweredOn)
    }

    @Test("any other raw value falls through to .unknown carrying the raw type")
    func unknownPreservesRawType() {
        let raw = 0xE000_FFFF
        #expect(IOKitPowerMessage.decode(rawType: raw) == .unknown(rawType: raw))
    }
}

@Suite("IOKitSleepWake lifecycle", .timeLimit(.minutes(1)))
struct IOKitSleepWakeLifecycleTests {
    @Test("dropping the observer without start() does not trip the deinit precondition")
    func dropWithoutStartIsSafe() {
        // Constructed and immediately released — handles are still zeroed,
        // so the deinit precondition (rootPort == 0) holds.
        _ = IOKitSleepWake()
    }

    @Test("stop() without start() is a no-op")
    func stopWithoutStartIsNoOp() async {
        let observer = IOKitSleepWake()
        await observer.stop()
        // No prior start, no grace tick can be armed.
        #expect(observer.consumeGraceTick() == false)
    }

    @Test("start() then stop() leaves no dangling handles and clears the grace flag")
    func startStopRoundTripIsClean() async {
        let observer = IOKitSleepWake()
        await observer.start()
        await observer.stop()
        // After stop, the handles snapshot is zeroed so deinit will pass and
        // the grace flag is reset whether or not the kernel delivered a
        // message during the brief registration window.
        #expect(observer.consumeGraceTick() == false)
    }

    @Test("isAsleep is false on a freshly constructed observer")
    func isAsleepFalseAtConstruction() {
        let observer = IOKitSleepWake()
        #expect(observer.isAsleep() == false)
    }

    @Test("isAsleep is false after a start/stop round-trip")
    func isAsleepFalseAfterStartStop() async {
        let observer = IOKitSleepWake()
        await observer.start()
        await observer.stop()
        #expect(observer.isAsleep() == false)
    }
}

@Suite("IOKitSleepWake sleep-state transitions", .timeLimit(.minutes(1)))
struct IOKitSleepWakeTransitionTests {
    @Test("canSystemSleep alone does not mark the engine asleep")
    func canSystemSleepDoesNotSleep() {
        // canSystemSleep is the revocable idle-sleep *query*. Treating it as a
        // commitment wedged the engine when a different process vetoed the
        // sleep (no willNotSleep handler reset the flag). HIGH-1 regression.
        let observer = IOKitSleepWake()
        observer.process(message: .canSystemSleep)
        #expect(observer.isAsleep() == false)
    }

    @Test("canSystemSleep then willSleep marks the engine asleep")
    func canSystemSleepThenWillSleepSleeps() {
        let observer = IOKitSleepWake()
        observer.process(message: .canSystemSleep)
        observer.process(message: .willSleep)
        #expect(observer.isAsleep() == true)
    }

    @Test("willSleep then willPowerOn round-trips back to awake")
    func willSleepThenWillPowerOnWakes() {
        let observer = IOKitSleepWake()
        observer.process(message: .willSleep)
        #expect(observer.isAsleep() == true)
        observer.process(message: .willPowerOn)
        #expect(observer.isAsleep() == false)
    }
}
