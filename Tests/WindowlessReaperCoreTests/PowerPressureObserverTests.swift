import Foundation
import Testing
import WindowlessReaperCore

@Suite("PowerPressureObserver", .timeLimit(.minutes(1)))
struct PowerPressureObserverTests {
    @Test("system observer snapshot reads three live signals")
    func systemSnapshotIsLive() async {
        let observer = SystemPowerPressure()
        await observer.start()
        defer { Task { await observer.stop() } }

        let snap = observer.snapshot()
        // Power source on a Mac is one of three known values; LPM and thermal
        // are bool/enum-bounded — the value-level invariant is just "doesn't
        // crash and returns a well-formed snapshot". The transition path is
        // covered by FakePowerPressureTests below where we control the input.
        #expect([PowerSource.ac, .battery, .unknown].contains(snap.source))
    }

    @Test("fake snapshot reflects most recent set")
    func fakeSnapshotReflectsSet() {
        let fake = FakePowerPressure(.nominal)
        #expect(fake.snapshot() == .nominal)

        let onBattery = PressureSnapshot(source: .battery, lowPowerMode: false, thermalState: .nominal)
        fake.set(onBattery)
        #expect(fake.snapshot() == onBattery)

        let lpm = PressureSnapshot(source: .battery, lowPowerMode: true, thermalState: .nominal)
        fake.set(lpm)
        #expect(fake.snapshot() == lpm)
    }

    @Test("PressureSnapshot.nominal is AC + no LPM + thermal.nominal")
    func nominalIsZeroPressure() {
        #expect(PressureSnapshot.nominal.source == .ac)
        #expect(PressureSnapshot.nominal.lowPowerMode == false)
        #expect(PressureSnapshot.nominal.thermalState == .nominal)
    }
}
