import Foundation
import Testing
import WindowlessReaperCore

private enum WatcherOutcome {
    case received
    case timeout
}

private func awaitWatcherChange(
    watcher: ConfigWatcher,
    timeout: Swift.Duration,
    trigger: @escaping @Sendable () async -> Void,
    matches: @escaping @Sendable (Config) async -> Bool
) async -> Bool {
    await withTaskGroup(of: Bool?.self) { group in
        group.addTask {
            for await result in watcher.events {
                if case .success(let config) = result, await matches(config) {
                    return true
                }
            }
            return nil
        }
        group.addTask {
            await trigger()
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        for await value in group {
            guard let value else { continue }
            group.cancelAll()
            return value
        }
        return false
    }
}

@Suite("ConfigWatcher", .timeLimit(.minutes(1)))
struct ConfigWatcherTests {
    @Test("watcherFiresOnFileChange")
    func watcherFiresOnFileChange() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-watch")
        defer { tmp.cleanup() }
        let configURL = tmp.child("config.toml")

        let initialTOML = """
        [settings]
        poll_interval    = "30s"
        log_level        = "info"
        dry_run          = false
        default_cooldown = "5x"

        [apps."com.apple.Safari"]
        timeout = "3m"
        """

        let updatedTOML = """
        [settings]
        poll_interval    = "60s"
        log_level        = "debug"
        dry_run          = false
        default_cooldown = "5x"

        [apps."com.apple.mail"]
        timeout = "10m"
        """

        try initialTOML.write(to: configURL, atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(url: configURL)
        await watcher.start()
        #expect(await AsyncWait.until { await watcher.isRunning() })

        let received = await awaitWatcherChange(
            watcher: watcher,
            timeout: .seconds(3),
            trigger: {
                await Task.yield()
                try? updatedTOML.write(to: configURL, atomically: true, encoding: .utf8)
            },
            matches: { $0.settings.pollInterval.seconds == 60 }
        )

        #expect(received)
        await watcher.finish()
    }

    @Test("watcher rearms after atomic-replace saves: subsequent edits still fire")
    func watcherRearmsAfterAtomicReplace() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-watch")
        defer { tmp.cleanup() }
        let configURL = tmp.child("config.toml")

        actor SeenFlags {
            var saw30 = false
            var saw60 = false

            func record(_ seconds: Int) {
                if seconds == 30 { saw30 = true }
                if seconds == 60 { saw60 = true }
            }

            func sawFirstReload() -> Bool {
                saw30
            }

            func bothSeen() -> Bool {
                saw30 && saw60
            }
        }
        let flags = SeenFlags()

        @Sendable func toml(pollSeconds: Int) -> String {
            """
            [settings]
            poll_interval    = "\(pollSeconds)s"
            log_level        = "info"
            dry_run          = false
            default_cooldown = "5x"
            """
        }

        try toml(pollSeconds: 10).write(to: configURL, atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(url: configURL)
        await watcher.start()
        #expect(await AsyncWait.until { await watcher.isRunning() })

        // Two atomic-replace saves in succession. The original FD points at
        // an inode that gets unlinked on the first replace; without rearm,
        // the second save fires no event.
        let bothSeen = await awaitWatcherChange(
            watcher: watcher,
            timeout: .seconds(5),
            trigger: {
                // First atomic replace.
                await Task.yield()
                try? toml(pollSeconds: 30).write(to: configURL, atomically: true, encoding: .utf8)
                #expect(await AsyncWait.until(timeout: .seconds(2)) { await flags.sawFirstReload() })
                // Second atomic replace — this is what breaks without rearm.
                await Task.yield()
                try? toml(pollSeconds: 60).write(to: configURL, atomically: true, encoding: .utf8)
            },
            matches: { config in
                await flags.record(config.settings.pollInterval.seconds)
                return await flags.bothSeen()
            }
        )

        #expect(bothSeen, "watcher must rearm after the first atomic replace and observe the second")
        await watcher.finish()
    }

    @Test("rearm gives up after exhausting retries when the file stays missing")
    func rearmExhaustionPausesWatcher() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-watch")
        defer { tmp.cleanup() }
        let configURL = tmp.child("config.toml")
        try "[settings]\npoll_interval=\"5s\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(url: configURL)
        await watcher.start()
        #expect(await AsyncWait.until { await watcher.isRunning() })

        // Removing the file fires .delete → handleEvent → rearm. Without a
        // file to reopen, every retry attempt fails and the watcher must
        // park with isRunning() == false rather than spinning forever.
        try FileManager.default.removeItem(at: configURL)

        // 5 retries × 100 ms delay = ~500 ms. Wait well past that window so
        // a transient isRunning() == false during a retry's sleep cannot mask
        // a rearm loop that never actually terminates.
        try await Task.sleep(for: .seconds(1))
        #expect(await !watcher.isRunning(), "rearm must exhaust retries and stay paused when the file is gone")

        // Recreating the file and restarting should bring the watcher back.
        try "[settings]\npoll_interval=\"5s\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        await watcher.start()
        #expect(await AsyncWait.until { await watcher.isRunning() }, "start() after exhaustion must resume watching")

        await watcher.finish()
    }

    @Test("start/stop are idempotent")
    func startStopIdempotent() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-watch")
        defer { tmp.cleanup() }
        let configURL = tmp.child("config.toml")
        try "[settings]\npoll_interval=\"5s\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(url: configURL)
        await watcher.start()
        await watcher.start() // double start must not crash or leak fds
        await watcher.stop()
        await watcher.stop() // double stop must be a no-op
        await watcher.start() // restart after stop
        await watcher.finish()
    }

    @Test("parse failure is delivered as Result.failure without crashing")
    func parseFailureSurfacesAsResult() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-watch")
        defer { tmp.cleanup() }
        let configURL = tmp.child("config.toml")
        try "[settings]\npoll_interval=\"5s\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(url: configURL)
        await watcher.start()
        #expect(await AsyncWait.until { await watcher.isRunning() })

        let outcome: Bool = await withTaskGroup(of: WatcherOutcome?.self) { group in
            group.addTask {
                for await result in watcher.events {
                    if case .failure = result { return .received }
                }
                return nil
            }
            group.addTask {
                await Task.yield()
                try? "[settings]\npoll_interval = not_a_duration\n"
                    .write(to: configURL, atomically: true, encoding: .utf8)
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return .timeout
            }
            var saw = false
            for await v in group {
                guard let v else { continue }
                switch v {
                case .received:
                    saw = true
                    group.cancelAll()
                    return saw
                case .timeout:
                    group.cancelAll()
                    return false
                }
            }
            return saw
        }

        #expect(outcome)
        await watcher.finish()
    }
}
