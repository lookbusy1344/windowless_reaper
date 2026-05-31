import Foundation

enum AsyncWait {
    static let defaultTimeout: Duration = .seconds(2)

    static func until(
        timeout: Duration = defaultTimeout,
        pollAfterYield: Bool = true,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await predicate() {
                return true
            }
            if pollAfterYield {
                await Task.yield()
            }
        }

        return await predicate()
    }

    static func awaitCompletion(
        of task: Task<Void, Never>,
        timeout: Duration = defaultTimeout
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: timeout)
                while clock.now < deadline {
                    await Task.yield()
                }
                return false
            }
            let result = await group.next() ?? false
            if !result {
                task.cancel()
            }
            group.cancelAll()
            return result
        }
    }
}
