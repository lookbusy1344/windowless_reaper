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
        // Scan immediately so the first observation lands at t=0.
        if !Task.isCancelled {
            await emitHealthSnapshotIfDue(now: clock.now())
            _ = await tick(dryRun: cliDryRun)
        }

        await withTaskGroup(of: EpochExit.self) { group in
            group.addTask { [self] in
                await tickLoop(cliDryRun: cliDryRun)
                return .tickLoopEnded
            }
            group.addTask { [self] in
                // Skip the initial "current state" yield — we only care
                // about transitions out of the visible-and-awake state.
                var first = true
                for await visible in powerState.transitions() {
                    if first {
                        first = false
                        continue
                    }
                    if !visible { return .visibilityLost }
                }
                return .streamClosed
            }
            group.addTask { [self] in
                var first = true
                for await awake in sleepWake.transitions() {
                    if first {
                        first = false
                        continue
                    }
                    if !awake { return .systemAsleep }
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
                await emitHealthSnapshotIfDue(now: clock.now())
                _ = await tick(dryRun: cliDryRun)
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
