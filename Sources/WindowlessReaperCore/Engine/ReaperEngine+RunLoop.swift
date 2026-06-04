import Foundation

/// Inner run-loop machinery: the suspend/resume waiters and the visible
/// epoch's task-group race. Kept out of the main engine file to stay
/// under the swiftlint file-length limit and so the three exit arms
/// (tick loop ending, visibility lost, system asleep) are reviewable
/// together.
extension ReaperEngine {
    func waitUntilVisible() async {
        for await visible in powerState.transitions() where visible {
            return
        }
    }

    func waitUntilAwake() async {
        for await awake in sleepWake.transitions() where awake {
            return
        }
    }

    func runVisibleEpoch(cliDryRun: Bool) async {
        // Scan immediately so the first observation lands at t=0. The health
        // snapshot is emitted *after* the tick so a post-wake dump reflects the
        // grace skip that tick consumed (the run-start baseline is seeded in
        // run()).
        if !Task.isCancelled {
            _ = await tick(dryRun: cliDryRun)
            await emitHealthSnapshotIfDue(now: clock.now())
        }

        await withTaskGroup(of: EpochExit.self) { group in
            group.addTask { [self] in
                await tickLoop(cliDryRun: cliDryRun)
                return .tickLoopEnded
            }
            // Level-triggered, not edge-triggered: act on every emission
            // including the on-subscribe snapshot. We only enter this epoch
            // when already visible-and-awake, so the snapshot is `true` and a
            // no-op. Skipping the first emission instead would race the
            // observer's snapshot against a real transition delivered in the
            // (non-atomic) subscribe window — the discarded `false` would then
            // strand the epoch, leaking the tick stream. See
            // SleepStateTickSuspensionTests "rapid sleep/wake flap".
            group.addTask { [self] in
                for await visible in powerState.transitions() where !visible {
                    return .visibilityLost
                }
                return .streamClosed
            }
            group.addTask { [self] in
                for await awake in sleepWake.transitions() where !awake {
                    return .systemAsleep
                }
                return .streamClosed
            }
            let exit = await group.next()
            group.cancelAll()
            switch exit {
            case .visibilityLost:
                logger.notice("visibility=off — suspending tick loop")
            case .systemAsleep:
                logger.notice("system asleep — suspending tick loop")
            default:
                break
            }
        }
    }

    enum EpochExit { case tickLoopEnded, visibilityLost, systemAsleep, streamClosed }

    func tickLoop(cliDryRun: Bool) async {
        while !Task.isCancelled {
            let baseInterval = config.settings.pollInterval
            let pressureSnap = pressure.snapshot()
            let effective = Self.effectiveInterval(baseInterval, snapshot: pressureSnap, adaptive: config.settings.adaptivePressure)
            if effective != baseInterval {
                logger.notice("effective pollInterval=\(effective) (base=\(baseInterval), pressure=\(Self.describePressure(pressureSnap)))")
            }
            let stream = clock.tickStream(interval: effective)
            for await _ in stream {
                if Task.isCancelled { break }
                _ = await tick(dryRun: cliDryRun)
                await emitHealthSnapshotIfDue(now: clock.now())
                if config.settings.pollInterval != baseInterval {
                    logger.notice(
                        "pollInterval changed \(baseInterval) -> \(config.settings.pollInterval); recreating tick stream"
                    )
                    break
                }
                let fresh = pressure.snapshot()
                let nextEffective = Self.effectiveInterval(config.settings.pollInterval, snapshot: fresh, adaptive: config.settings.adaptivePressure)
                if nextEffective != effective {
                    logger.notice(
                        "effective pollInterval changed \(effective) -> \(nextEffective); recreating tick stream"
                    )
                    break
                }
            }
        }
    }

    static func describePressure(_ s: PressureSnapshot) -> String {
        "source=\(s.source) lpm=\(s.lowPowerMode) thermal=\(s.thermalState)"
    }
}
