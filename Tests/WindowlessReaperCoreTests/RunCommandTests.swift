import Dispatch
import Foundation
import Logging
import struct os.OSAllocatedUnfairLock
import Testing
import WindowlessReaperCore
@testable import wreaper

@Suite("RunCommand startup AX gate", .timeLimit(.minutes(1)))
struct RunCommandStartupAXGateTests {
    @Test("trusted always proceeds, interactive or launchd")
    func trustedProceeds() {
        #expect(RunCommand.startupAXGate(managedByLaunchd: false, isTrusted: true) == .proceed)
        #expect(RunCommand.startupAXGate(managedByLaunchd: true, isTrusted: true) == .proceed)
    }

    @Test("interactive run without trust refuses to start")
    func interactiveUntrustedRequiresTrust() {
        #expect(RunCommand.startupAXGate(managedByLaunchd: false, isTrusted: false) == .requireTrust)
    }

    @Test("launchd-managed run without trust proceeds (waits for trust at runtime)")
    func launchdUntrustedProceeds() {
        // MEDIUM-1: KeepAlive:true + hard AX exit was a ~10s crash-loop while
        // the user grants AX. The engine pauses evictions until trust appears,
        // so the daemon should enter the loop rather than exit.
        #expect(RunCommand.startupAXGate(managedByLaunchd: true, isTrusted: false) == .proceed)
    }

    @Test("launchd detection keys off XPC_SERVICE_NAME containing the agent label")
    func launchdDetection() {
        #expect(RunCommand.isManagedByLaunchd(environment: [:]) == false)
        #expect(RunCommand.isManagedByLaunchd(environment: ["XPC_SERVICE_NAME": "unrelated"]) == false)
        #expect(RunCommand.isManagedByLaunchd(
            environment: ["XPC_SERVICE_NAME": "application.\(LaunchAgentPlist.label).12345"]
        ) == true)
    }
}

@Suite("RunCommand signal ordering", .serialized, .timeLimit(.minutes(1)))
struct RunCommandTests {
    @Test("signal dispositions are set to SIG_IGN before returning from installSignalHandlers")
    func signalDispositionsAreSIGIGN() {
        let runCommand = RunCommand()
        let logger = Logger(label: "test")

        let sources = runCommand.installSignalHandlers(
            requestCancel: {},
            logger: logger
        )
        defer {
            sources.sigint.resume()
            sources.sigterm.resume()
            sources.sighup.resume()
            sources.sigint.cancel()
            sources.sigterm.cancel()
            sources.sighup.cancel()
        }

        let prevSIGINT = signal(SIGINT, SIG_DFL)
        signal(SIGINT, prevSIGINT)

        let prevSIGTERM = signal(SIGTERM, SIG_DFL)
        signal(SIGTERM, prevSIGTERM)

        let prevSIGHUP = signal(SIGHUP, SIG_DFL)
        signal(SIGHUP, prevSIGHUP)

        // Compare the raw function pointers to verify SIG_IGN was installed.
        #expect(unsafeBitCast(prevSIGINT, to: UnsafeRawPointer.self) == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer.self))
        #expect(unsafeBitCast(prevSIGTERM, to: UnsafeRawPointer.self) == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer.self))
        #expect(unsafeBitCast(prevSIGHUP, to: UnsafeRawPointer.self) == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer.self))
    }

    /// The dispatch sources must come back suspended so the caller can
    /// publish the cancel target before any signal can drive the handler.
    /// If the source were already resumed, a SIGTERM arriving in the
    /// window between `installSignalHandlers` returning and the cancel
    /// closure being populated would be swallowed (SIG_IGN holds) but
    /// would not cancel anything — the engine would keep running until a
    /// second signal arrived.
    @Test("installSignalHandlers returns suspended sources so cancel target can be published first")
    func sourcesReturnSuspended() async throws {
        let runCommand = RunCommand()
        let logger = Logger(label: "test")

        let fired = OSAllocatedUnfairLock<Bool>(initialState: false)
        let sources = runCommand.installSignalHandlers(
            requestCancel: { fired.withLock { $0 = true } },
            logger: logger
        )
        defer {
            sources.sigint.resume()
            sources.sigterm.resume()
            sources.sighup.resume()
            sources.sigint.cancel()
            sources.sigterm.cancel()
            sources.sighup.cancel()
        }

        kill(getpid(), SIGTERM)
        // The handler must not fire while the source is suspended. SIG_IGN
        // keeps the process alive regardless of whether the dispatch source
        // is observing.
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired.withLock { $0 } == false)
    }
}
