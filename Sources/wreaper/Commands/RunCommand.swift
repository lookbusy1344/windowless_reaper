import ArgumentParser
import Dispatch
import Foundation
import Logging
import struct os.OSAllocatedUnfairLock
import WindowlessReaperCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the foreground engine loop, reaping windowless apps."
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let url = ConfigPath.resolve(override: globals.config)
        let config = try ConfigPath.load(from: url)
        installFileSinkIfManagedByLaunchd()
        try GlobalOptions.bootstrapLogging(globals: globals, config: config)
        let logger = Logger(label: "wreaper.run")
        let effectiveDryRun = globals.dryRun || config.settings.dryRun
        logger.notice(
            "starting config=\(url.path) logLevel=\(LogLevelBootstrap.currentLevel) pollInterval=\(config.settings.pollInterval) dryRun=\(effectiveDryRun)"
        )

        let trusted = AccessibilityPermission().isTrusted()
        switch Self.startupAXGate(managedByLaunchd: Self.isManagedByLaunchd(), isTrusted: trusted) {
        case .requireTrust:
            try await CLIPermissions.requireAccessibility()
        case .proceed:
            if !trusted {
                logger.notice(
                    "accessibility not yet granted — managed by launchd, evictions paused until trust appears (re-checked each tick)"
                )
            }
        }
        let engine = makeEngine(config: config)
        let watcher = ConfigWatcher(url: url)
        await watcher.start()
        let reloadTask = startReloadTask(watcher: watcher, engine: engine, url: url, logger: logger)

        // Install signal handlers before the engine task so that SIG_IGN is
        // in effect before the engine can be mid-restore on the checkpoint.
        // SIG_IGN takes effect inside installSignalHandlers; the dispatch
        // sources are returned suspended and only armed after the cancel
        // target is published, eliminating the window where a SIGTERM could
        // fire with a nil cancel closure.
        let cancelAction = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: .none)
        let signals = installSignalHandlers(
            requestCancel: { cancelAction.withLock { $0?() } },
            logger: logger
        )
        let runTask = Task { await engine.run(dryRun: globals.dryRun) }
        cancelAction.withLock { $0 = { runTask.cancel() } }
        signals.sigint.resume()
        signals.sigterm.resume()
        signals.sighup.resume()

        await runTask.value

        signals.sigint.cancel()
        signals.sigterm.cancel()
        signals.sighup.cancel()
        await watcher.finish()
        await reloadTask.value
    }

    /// Startup Accessibility-trust decision. Interactive `wreaper run` refuses
    /// to start without trust (otherwise it would reap everything in the
    /// allowlist). Under launchd we *proceed* without trust and wait for it at
    /// runtime — the engine treats every bundle as `.unknown` (evictions
    /// paused) and re-checks each tick. This avoids the `KeepAlive: true`
    /// crash-loop on the ~10 s throttle floor during the common first-run state
    /// "agent installed, AX not yet granted".
    enum StartupAXGate: Equatable {
        case proceed
        case requireTrust
    }

    static func startupAXGate(managedByLaunchd: Bool, isTrusted: Bool) -> StartupAXGate {
        if isTrusted { return .proceed }
        return managedByLaunchd ? .proceed : .requireTrust
    }

    /// Detect the LaunchAgent context by the `XPC_SERVICE_NAME` env var that
    /// `launchd` sets to our plist label.
    static func isManagedByLaunchd(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let xpc = environment["XPC_SERVICE_NAME"] else { return false }
        return xpc.contains(LaunchAgentPlist.label)
    }

    /// Route logs to a rotated file when running under `launchd`. Interactive
    /// `wreaper run` keeps emitting to stderr.
    private func installFileSinkIfManagedByLaunchd() {
        guard Self.isManagedByLaunchd() else { return }
        let logURL = UserPaths().logURL(relativePath: LaunchAgentPlist.logRelativePath)
        LogLevelBootstrap.installFileSink(at: logURL)
    }

    private func makeEngine(config: Config) -> ReaperEngine {
        ReaperEngine(
            config: config,
            enumerator: NSWorkspaceAppEnumerator(),
            inspector: AXWindowInspector(),
            terminator: NSRunningApplicationTerminator(),
            clock: SystemClock(),
            sleepWake: CompositeSleepWakeObserver([NSWorkspaceSleepWake(), IOKitSleepWake()]),
            powerState: NSWorkspaceScreenWake(),
            pressure: SystemPowerPressure(),
            checkpointer: FileCheckpointer(url: FileCheckpointer.defaultURL()),
            permissionProbe: AccessibilityPermission(),
            diagnosticsSink: FileDiagnosticsSink(url: FileDiagnosticsSink.defaultURL())
        )
    }

    private func startReloadTask(
        watcher: ConfigWatcher,
        engine: ReaperEngine,
        url: URL,
        logger: Logger
    ) -> Task<Void, Never> {
        let cliLogLevelSet = globals.logLevel != nil
        return Task {
            for await result in watcher.events {
                switch result {
                case .success(let newConfig):
                    if !cliLogLevelSet, let lvl = try? LogLevelBootstrap.parse(newConfig.settings.logLevel) {
                        LogLevelBootstrap.apply(lvl)
                    }
                    logger.notice("config reloaded path=\(url.path) logLevel=\(LogLevelBootstrap.currentLevel)")
                    await engine.updateConfig(newConfig)
                case .failure(let error):
                    logger.error("config reload failed: \(error)")
                }
            }
        }
    }

    struct SignalSources {
        let sigint: any DispatchSourceSignal
        let sigterm: any DispatchSourceSignal
        let sighup: any DispatchSourceSignal
    }

    /// Sets SIG_IGN for SIGINT/SIGTERM/SIGHUP and creates dispatch sources
    /// with handlers wired up, but returns the sources **suspended**. The
    /// caller must `resume()` each source after publishing its cancel
    /// target so that a signal cannot fire the handler before
    /// `requestCancel` is fully populated. SIGHUP triggers a log-sink
    /// reopen, matching the conventional Unix-daemon contract for use
    /// with `newsyslog`/`logrotate`-style external rotators.
    func installSignalHandlers(
        requestCancel: @Sendable @escaping () -> Void,
        logger: Logger
    ) -> SignalSources {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let sighup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        sigint.setEventHandler {
            logger.notice("SIGINT received")
            LogLevelBootstrap.flushSink()
            requestCancel()
        }
        sigterm.setEventHandler {
            logger.notice("SIGTERM received")
            LogLevelBootstrap.flushSink()
            requestCancel()
        }
        sighup.setEventHandler {
            logger.notice("SIGHUP received — reopening log sink")
            LogLevelBootstrap.flushSink()
            LogLevelBootstrap.reopenSink()
        }
        return SignalSources(sigint: sigint, sigterm: sigterm, sighup: sighup)
    }
}
