import Foundation
import Testing
import WindowlessReaperCore

@Suite("Logging — rotating file sink", .timeLimit(.minutes(1)))
struct LoggingRotationTests {
    @Test("rotates to .1 once the active file exceeds maxBytes")
    func sinkRotatesPastThreshold() throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-log")
        defer { tmp.cleanup() }
        let logPath = tmp.child("wr.log")
        let backupPath = tmp.child("wr.log.1")
        let maxBytes = 1024
        let sink = RotatingFileSink(path: logPath, maxBytes: maxBytes)

        // Each line is ~64 bytes; writing 100 of them well exceeds 1 KB and
        // forces at least one rotation.
        let line = String(repeating: "x", count: 60) + "\n"
        for _ in 0 ..< 100 {
            sink.write(line)
        }
        sink.flush()

        #expect(FileManager.default.fileExists(atPath: backupPath.path), "rotation must produce a .1 backup")

        let activeSize = try FileManager.default.attributesOfItem(atPath: logPath.path)[.size] as? Int ?? -1
        #expect(activeSize >= 0)
        #expect(activeSize <= maxBytes * 2, "active file must remain bounded (got \(activeSize) bytes)")
    }

    @Test("rotation replaces the prior .1 backup rather than accreting generations")
    func sinkKeepsSingleBackupGeneration() throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-log")
        defer { tmp.cleanup() }
        let logPath = tmp.child("wr.log")
        let maxBytes = 512
        let sink = RotatingFileSink(path: logPath, maxBytes: maxBytes)

        let line = String(repeating: "y", count: 60) + "\n"
        // Force several rotations.
        for _ in 0 ..< 500 {
            sink.write(line)
        }
        sink.flush()

        let parent = tmp.url.path
        let entries = try FileManager.default.contentsOfDirectory(atPath: parent)
            .filter { $0.hasPrefix("wr.log") }
        // Exactly the active file + one .1 backup, never .2/.3.
        #expect(entries.count == 2, "expected 2 files (active + .1), got \(entries)")
    }

    /// Polls until `predicate` is true or `timeout` elapses, writing a
    /// probe line on each iteration so the sink has a chance to observe
    /// its vnode source event and recreate the file. Returns whether the
    /// predicate ever became true.
    private func waitForAutoRecovery(
        sink: RotatingFileSink,
        timeout: TimeInterval = 2.0,
        probe: String,
        predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            sink.write(probe)
            sink.flush()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("auto-recovers when an external process renames the active file out of the way")
    func sinkAutoRecoversFromExternalRename() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-log")
        defer { tmp.cleanup() }
        let logPath = tmp.child("wr.log")
        let archivedPath = tmp.child("wr.log.archived")
        let sink = RotatingFileSink(path: logPath, maxBytes: 1024 * 1024)

        sink.write("before-rename\n")
        sink.flush()
        try FileManager.default.moveItem(at: logPath, to: archivedPath)

        let recovered = await waitForAutoRecovery(sink: sink, probe: "after-rename\n") {
            guard FileManager.default.fileExists(atPath: logPath.path) else { return false }
            return (try? String(contentsOf: logPath, encoding: .utf8))?.contains("after-rename") ?? false
        }
        #expect(recovered, "sink must recreate the log file at the original path after external rename")
        // The pre-rename line is preserved on the renamed inode. We don't
        // assert exclusivity of "after-rename" content: the FD remains
        // bound to the renamed inode until the vnode source fires, so a
        // bounded number of early probes legitimately land in the
        // archived file. The recovery guarantee is that *new* writes
        // resume landing at `logPath` — verified by `recovered` above.
        let archived = try String(contentsOf: archivedPath, encoding: .utf8)
        #expect(archived.contains("before-rename"))
    }

    @Test("auto-recovers when an external process deletes the active file")
    func sinkAutoRecoversFromExternalDelete() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-log")
        defer { tmp.cleanup() }
        let logPath = tmp.child("wr.log")
        let sink = RotatingFileSink(path: logPath, maxBytes: 1024 * 1024)

        sink.write("before-delete\n")
        sink.flush()
        try FileManager.default.removeItem(at: logPath)

        let recovered = await waitForAutoRecovery(sink: sink, probe: "after-delete\n") {
            guard FileManager.default.fileExists(atPath: logPath.path) else { return false }
            return (try? String(contentsOf: logPath, encoding: .utf8))?.contains("after-delete") ?? false
        }
        #expect(recovered, "sink must recreate the log file at the original path after external delete")
    }

    @Test("auto-recovers when an external process atomically replaces the active file")
    func sinkAutoRecoversFromAtomicReplace() async throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-log")
        defer { tmp.cleanup() }
        let logPath = tmp.child("wr.log")
        let stagingPath = tmp.child("wr.log.new")
        let sink = RotatingFileSink(path: logPath, maxBytes: 1024 * 1024)

        sink.write("before-replace\n")
        sink.flush()

        // Atomic replace: write a new file and rename it over the original.
        // The original inode becomes an unlinked orphan that the daemon's
        // open FileHandle was bound to.
        try "external-content\n".write(to: stagingPath, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(logPath, withItemAt: stagingPath)

        let recovered = await waitForAutoRecovery(sink: sink, probe: "after-replace\n") {
            guard let contents = try? String(contentsOf: logPath, encoding: .utf8) else { return false }
            return contents.contains("after-replace")
        }
        #expect(recovered, "sink must reopen onto the replaced inode and resume writing")
        let active = try String(contentsOf: logPath, encoding: .utf8)
        #expect(active.contains("external-content"), "the externally-staged content must be preserved")
    }

    @Test("reopen() rebinds the handle after external rename so new writes land in the new file")
    func sinkReopenAfterExternalRename() throws {
        let tmp = try TemporaryDirectory(prefix: "wreaper-log")
        defer { tmp.cleanup() }
        let logPath = tmp.child("wr.log")
        let archivedPath = tmp.child("wr.log.archived")
        let sink = RotatingFileSink(path: logPath, maxBytes: 1024 * 1024)

        sink.write("before-rotation\n")
        sink.flush()

        // Simulate an external rotator: rename the active file aside. The
        // daemon's open FileHandle is now bound to the orphan inode.
        try FileManager.default.moveItem(at: logPath, to: archivedPath)

        // Without reopen(), this write would land in the orphan inode and
        // logPath would stay missing. With reopen(), the handle is dropped
        // and the next write re-creates the file at logPath.
        sink.reopen()
        sink.write("after-rotation\n")
        sink.flush()

        #expect(FileManager.default.fileExists(atPath: logPath.path), "logPath must exist after reopen + write")
        let archived = try String(contentsOf: archivedPath, encoding: .utf8)
        let active = try String(contentsOf: logPath, encoding: .utf8)
        #expect(archived.contains("before-rotation"))
        #expect(!archived.contains("after-rotation"), "post-reopen line must not land in the archived file")
        #expect(active.contains("after-rotation"))
        #expect(!active.contains("before-rotation"), "pre-reopen line must not appear in the new active file")
    }
}
