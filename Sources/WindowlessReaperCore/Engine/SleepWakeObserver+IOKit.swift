import Foundation
import IOKit
import IOKit.pwr_mgt
import Logging
import Synchronization

struct IOKitSystemPowerRegistration {
    let rootPort: io_connect_t
    let notifier: io_object_t
    let notificationPort: IONotificationPortRef?
}

protocol IOKitSystemPowerRegistering: Sendable {
    func register(
        refcon: UnsafeMutableRawPointer,
        callback: IOServiceInterestCallback,
        notifier: inout io_object_t
    ) -> IOKitSystemPowerRegistration?

    func deregister(_ registration: IOKitSystemPowerRegistration)
}

struct DefaultIOKitSystemPowerRegistrar: IOKitSystemPowerRegistering {
    func register(
        refcon: UnsafeMutableRawPointer,
        callback: IOServiceInterestCallback,
        notifier: inout io_object_t
    ) -> IOKitSystemPowerRegistration? {
        var notifyPort: IONotificationPortRef?
        let rootPort = IORegisterForSystemPower(refcon, &notifyPort, callback, &notifier)
        guard rootPort != MACH_PORT_NULL, let port = notifyPort else {
            if rootPort != MACH_PORT_NULL {
                IOServiceClose(rootPort)
            }
            return nil
        }

        return IOKitSystemPowerRegistration(
            rootPort: rootPort,
            notifier: notifier,
            notificationPort: port
        )
    }

    func deregister(_ registration: IOKitSystemPowerRegistration) {
        var notifier = registration.notifier
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        if let port = registration.notificationPort {
            IONotificationPortDestroy(port)
        }
        if registration.rootPort != 0 {
            IOServiceClose(registration.rootPort)
        }
    }
}

/// `SleepWakeObserver` backed by IOKit's `IORegisterForSystemPower`.
///
/// Why we need this *and* `NSWorkspaceSleepWake`: NSWorkspace only posts
/// `didWakeNotification` on full user wake. On AC power, macOS prefers dark
/// wake / Power Nap — the CPU runs for background maintenance with the
/// display off — and NSWorkspace stays silent. IOKit fires
/// `kIOMessageSystemHasPoweredOn` for every wake including dark wake, so
/// composing the two observers means a grace skip fires no matter which
/// path macOS uses to bring us back.
///
/// **Sleep acknowledgement.** macOS expects us to call `IOAllowPowerChange`
/// in response to `kIOMessageCanSystemSleep` and `kIOMessageSystemWillSleep`.
/// If we don't, the system stalls for ~30 s before forcing the transition.
/// We always allow — we have no reason to block sleep.
public final class IOKitSleepWake: SleepWakeObserver {
    /// IOKit handles, stored as raw integer bit patterns so the struct is
    /// trivially `Sendable` (the project's M10 release test bans concurrency
    /// escape hatches). `IONotificationPortRef` is an `OpaquePointer` with no
    /// Sendable conformance — round-tripping through `UInt` lets the Mutex
    /// carry it cleanly. Zero means "not registered".
    private struct Handles {
        var rootPort: io_connect_t = 0
        var notifier: io_object_t = 0
        var notificationPortBits: UInt = 0
    }

    private let handles: Mutex<Handles> = Mutex(Handles())
    private let graceTickPending: Mutex<Bool> = Mutex(false)
    private let asleep: Mutex<Bool> = Mutex(false)
    private let waiters: Mutex<[UUID: AsyncStream<Bool>.Continuation]> = Mutex([:])
    private let queue: DispatchQueue
    private let logger: Logger
    private let registrar: any IOKitSystemPowerRegistering

    deinit {
        let snapshot = handles.withLock { $0 }
        precondition(snapshot.rootPort == 0, "IOKitSleepWake.stop() must be called before deinit — dangling IOKit callback would crash")
    }

    public convenience init(logger: Logger = Logger(label: "wreaper.iokit-power")) {
        self.init(logger: logger, registrar: DefaultIOKitSystemPowerRegistrar())
    }

    init(logger: Logger = Logger(label: "wreaper.iokit-power"), registrar: any IOKitSystemPowerRegistering) {
        self.logger = logger
        self.registrar = registrar
        queue = DispatchQueue(label: "wreaper.iokit-power")
    }

    public func start() async {
        if handles.withLock({ $0.rootPort != 0 }) {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = 0

        guard let registration = registrar.register(
            refcon: refcon,
            callback: Self.powerCallback,
            notifier: &notifier
        ) else {
            logger.error("IORegisterForSystemPower failed — IOKit wake notifications disabled")
            return
        }

        if let port = registration.notificationPort {
            IONotificationPortSetDispatchQueue(port, queue)
        }

        handles.withLock {
            $0.rootPort = registration.rootPort
            $0.notificationPortBits = registration.notificationPort.map { UInt(bitPattern: $0) } ?? 0
            $0.notifier = notifier
        }
        logger.notice("iokit power observer started")
    }

    public func stop() async {
        let snapshot = handles.withLock { h -> Handles in
            let captured = h
            h = Handles()
            return captured
        }
        graceTickPending.withLock { $0 = false }
        asleep.withLock { $0 = false }
        let drained = waiters.withLock { w -> [AsyncStream<Bool>.Continuation] in
            let copy = Array(w.values)
            w.removeAll()
            return copy
        }
        for w in drained {
            w.finish()
        }
        registrar.deregister(
            IOKitSystemPowerRegistration(
                rootPort: snapshot.rootPort,
                notifier: snapshot.notifier,
                notificationPort: IONotificationPortRef(bitPattern: snapshot.notificationPortBits)
            )
        )
    }

    public func transitions() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = !asleep.withLock { $0 }
            waiters.withLock { $0[id] = continuation }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.waiters.withLock { $0[id] = nil }
            }
        }
    }

    public func consumeGraceTick() -> Bool {
        graceTickPending.withLock { pending in
            let was = pending
            pending = false
            return was
        }
    }

    public func isAsleep() -> Bool {
        asleep.withLock { $0 }
    }

    var isRegistered: Bool {
        handles.withLock { $0.rootPort != 0 }
    }

    private static let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
        guard let refcon else { return }
        let observer = Unmanaged<IOKitSleepWake>.fromOpaque(refcon).takeUnretainedValue()
        observer.handleMessage(messageType: messageType, messageArgument: messageArgument)
    }

    private func handleMessage(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        let message = IOKitPowerMessage.decode(rawType: Int(messageType))
        // Acknowledge both the idle-sleep *query* and the sleep *commitment* so
        // the system does not stall ~30 s waiting on our response. State changes
        // are deferred to `process(message:)` and happen only on willSleep.
        switch message {
        case .canSystemSleep, .willSleep:
            let rootPort = handles.withLock { $0.rootPort }
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
        default:
            break
        }
        process(message: message)
    }

    /// State-transition logic, split from the IOKit acknowledgement above so the
    /// `canSystemSleep → willSleep` / `canSystemSleep → willNotSleep` sequences
    /// are testable without a real `IORegisterForSystemPower` callback.
    func process(message: IOKitPowerMessage) {
        switch message {
        case .canSystemSleep:
            // Revocable idle-sleep *query*, not a commitment to sleep. macOS
            // collects responses and then sends either willSleep (proceed) or
            // willNotSleep (aborted — another process held a sleep assertion,
            // user activity resumed, …). Marking asleep here wedged the engine
            // in `waitUntilAwake()` whenever the sleep was vetoed, since nothing
            // reset the flag. willSleep follows within ms if sleep proceeds, so
            // deferring the state change loses nothing.
            logger.notice("iokit power: canSystemSleep (acknowledged, state unchanged)")
        case .willSleep:
            let changed = asleep.withLock { current -> Bool in
                let was = current
                current = true
                return !was
            }
            logger.notice("iokit power: system will sleep (acknowledged)")
            if changed { broadcast(awake: false) }
        case .willPowerOn:
            let changed = asleep.withLock { current -> Bool in
                let was = current
                current = false
                return was
            }
            graceTickPending.withLock { $0 = true }
            logger.notice("iokit power: system powered on (willPowerOn) — AX grace period")
            if changed { broadcast(awake: true) }
        case .hasPoweredOn:
            let stillAsleep = asleep.withLock { current -> Bool in
                let was = current
                current = false
                return was
            }
            if stillAsleep {
                logger.warning("hasPoweredOn arrived while still marked asleep — willPowerOn likely missed")
            }
            graceTickPending.withLock { $0 = true }
            logger.notice("iokit power: system powered on (hasPoweredOn) — AX grace period")
            if stillAsleep { broadcast(awake: true) }
        case .unknown(let raw):
            logger.notice("iokit power: unhandled message type 0x\(String(raw, radix: 16, uppercase: false))")
        }
    }

    private func broadcast(awake: Bool) {
        let snapshot = waiters.withLock { Array($0.values) }
        for w in snapshot {
            w.yield(awake)
        }
    }
}

/// Pure-value decoder for IOKit system-power messages. Split out from
/// `IOKitSleepWake` so the branch logic is testable without registering a
/// real `IORegisterForSystemPower` callback (which requires a console session
/// and would couple the test suite to kernel state).
///
/// Constants are from `<IOKit/IOMessage.h>`. The macros are marked "structure
/// not supported" in the Swift import on recent SDKs, but the wire values are
/// stable ABI: `sys_iokit (0xE0000000) | sub_iokit_common (0) | <code>`.
public enum IOKitPowerMessage: Equatable {
    case canSystemSleep
    case willSleep
    case willPowerOn
    case hasPoweredOn
    case unknown(rawType: Int)

    public static let canSystemSleepRawValue: Int = 0xE000_0270
    public static let willSleepRawValue: Int = 0xE000_0280
    public static let willPowerOnRawValue: Int = 0xE000_0320
    public static let hasPoweredOnRawValue: Int = 0xE000_0300

    public static func decode(rawType: Int) -> IOKitPowerMessage {
        switch rawType {
        case canSystemSleepRawValue: .canSystemSleep
        case willSleepRawValue: .willSleep
        case willPowerOnRawValue: .willPowerOn
        case hasPoweredOnRawValue: .hasPoweredOn
        default: .unknown(rawType: rawType)
        }
    }
}
