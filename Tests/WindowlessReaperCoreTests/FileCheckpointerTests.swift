import Foundation
import Testing
import WindowlessReaperCore

@Suite("FileCheckpointer", .timeLimit(.minutes(1)))
struct FileCheckpointerTests {
    private func makeCheckpointer() throws -> (FileCheckpointer, TemporaryDirectory) {
        let tmp = try TemporaryDirectory()
        let url = tmp.url.appendingPathComponent("state.json")
        return (FileCheckpointer(url: url), tmp)
    }

    @Test("save → load round-trips the snapshot")
    func roundTrip() async throws {
        let (cp, tmp) = try makeCheckpointer()
        defer { tmp.cleanup() }

        let snapshot = TrackerSnapshot(entries: [
            .init(bundleID: "com.apple.Safari", kind: .tracked, elapsedSeconds: 247, timeoutSeconds: 300),
            .init(bundleID: "com.apple.mail", kind: .cooldown, elapsedSeconds: 580, timeoutSeconds: nil),
        ])

        try await cp.save(snapshot)
        let loaded = await cp.load()
        #expect(loaded == snapshot)
    }

    @Test("load returns nil when file is absent")
    func loadMissingReturnsNil() async throws {
        let (cp, tmp) = try makeCheckpointer()
        defer { tmp.cleanup() }
        let loaded = await cp.load()
        #expect(loaded == nil)
    }

    @Test("load returns nil for corrupt JSON")
    func loadCorruptReturnsNil() async throws {
        let (cp, tmp) = try makeCheckpointer()
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("state.json")
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)

        let loaded = await cp.load()
        #expect(loaded == nil)
    }

    @Test("load returns nil for unknown schema version")
    func loadFutureVersionReturnsNil() async throws {
        let (cp, tmp) = try makeCheckpointer()
        defer { tmp.cleanup() }

        let future = TrackerSnapshot(entries: [], version: 999)
        try await cp.save(future)
        let loaded = await cp.load()
        #expect(loaded == nil, "future-version checkpoint must not be applied")
    }

    @Test("save creates the parent directory lazily")
    func saveCreatesParent() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        // Two levels deep — neither exists yet.
        let url = tmp.url
            .appendingPathComponent("nested")
            .appendingPathComponent("deeper")
            .appendingPathComponent("state.json")
        let cp = FileCheckpointer(url: url)
        try await cp.save(TrackerSnapshot(entries: []))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
