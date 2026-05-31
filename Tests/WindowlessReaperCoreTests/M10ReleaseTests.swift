import Foundation
import Testing
import WindowlessReaperCore

@Suite("M10 release artifacts", .timeLimit(.minutes(1)))
struct M10ReleaseTests {
    @Test("readmeExamplesCompile")
    func readmeExamplesCompile() throws {
        let readme = try Self.locate("README.md")
        let blocks = Self.fencedBlocks(in: readme, language: "toml")
        try #require(!blocks.isEmpty, "README must contain at least one ```toml example")
        for (index, block) in blocks.enumerated() {
            do {
                _ = try ConfigLoader.load(toml: block)
            } catch {
                Issue.record("README toml block #\(index) failed to load: \(error)\n---\n\(block)\n---")
            }
        }
    }

    @Test("readmeContainsSampleConfig")
    func readmeContainsSampleConfig() throws {
        let readme = try Self.locate("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        // The canonical sample lives in ConfigSample; the README should reference the same shape.
        #expect(text.contains("[settings]"), "README should document the [settings] block")
        #expect(text.contains("poll_interval"), "README should document poll_interval")
        #expect(text.contains("wreaper"), "README should reference the wreaper binary")
    }

    @Test("distributionGuideExists")
    func distributionGuideExists() throws {
        let url = try Self.locate("DISTRIBUTION.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("notar"), "DISTRIBUTION.md should mention notarisation")
        #expect(text.contains("codesign") || text.contains("scripts/sign.sh"),
                "DISTRIBUTION.md should reference signing")
    }

    @Test("packageManifestUsesTypedWarningSettingsAndSupportedDeploymentFloor")
    func packageManifestShape() throws {
        let url = try Self.locate("Package.swift")
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.contains(".treatAllWarnings(as: .error)"),
                "Package.swift should use typed SwiftPM warning settings")
        #expect(!text.contains(".unsafeFlags([\"-warnings-as-errors\""),
                "Package.swift should not use raw warnings-as-errors flags")
        #expect(text.contains("platforms: [.macOS(.v15)]"),
                "Package.swift should declare the intended deployment floor")
    }

    @Test("releaseScriptIsExecutable")
    func releaseScriptIsExecutable() throws {
        let url = try Self.locate("scripts/release.sh")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0, "scripts/release.sh should be executable")
    }

    @Test("release.sh declares --dry-run, env-var preflight, and spctl validation")
    func releaseScriptShape() throws {
        let url = try Self.locate("scripts/release.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("--dry-run"), "release.sh should expose --dry-run for credential-free preflight")
        #expect(text.contains("WREAPER_SIGNING_IDENTITY"), "release.sh should declare required Apple env vars")
        #expect(text.contains("WREAPER_NOTARY_PROFILE"), "release.sh should reference the notary keychain profile")
        #expect(text.contains("spctl") || text.contains("stapler validate"),
                "release.sh should validate the signed artifact before tagging")
        // The tag must only land after notarisation/stapling succeeds.
        let tagIdx = try #require(text.range(of: "git tag -a"))
        let stapleIdx = try #require(text.range(of: "stapler staple"))
        #expect(stapleIdx.upperBound < tagIdx.lowerBound, "stapler staple must run before git tag")
        // The script may *print* a `git push` instruction for the human, but
        // it must not invoke push itself.
        let pushedInvocations = text
            .components(separatedBy: "\n")
            .filter { line in
                let stripped = line.trimmingCharacters(in: .whitespaces)
                return stripped.hasPrefix("git push") || stripped.contains("$(git push") || stripped.contains("&& git push")
            }
        #expect(pushedInvocations.isEmpty,
                "release.sh must not push — DISTRIBUTION.md asks the human to push manually")
    }

    @Test("noTODOsInSources")
    func noTODOsInSources() throws {
        let sources = try Self.locate("Sources")
        let offenders = Self.filesContaining(["TODO", "FIXME", "XXX"], under: sources)
        #expect(offenders.isEmpty, "TODO/FIXME/XXX found in Sources/: \(offenders.joined(separator: ", "))")
    }

    @Test("noConcurrencyEscapeHatchesInSources")
    func noConcurrencyEscapeHatchesInSources() throws {
        let sources = try Self.locate("Sources")
        let offenders = Self.filesContainingRaw(["@unchecked Sendable", "nonisolated(unsafe)"], under: sources)
        #expect(offenders.isEmpty,
                "@unchecked Sendable/nonisolated(unsafe) found in Sources/: \(offenders.joined(separator: ", "))")
    }

    @Test("@testable import footprint is tracked")
    func ableImportFootprintIsTracked() throws {
        let tests = try Self.locate("Tests")
        let offenders = Self.filesContainingRaw(["@testable import WindowlessReaperCore"], under: tests)
        #expect(offenders.count == 7, "current @testable import count is technical debt: \(offenders.sorted().joined(separator: ", "))")
    }

    @Test("process-spawn helpers are centralized")
    func processSpawnHelpersAreCentralized() throws {
        let tests = try Self.locate("Tests")
        let offenders = Self.filesContainingRaw(
            ["waitUntilExit(", ".build/arm64-apple-macosx/debug"],
            under: tests,
            ignoring: ["M10ReleaseTests.swift", "TestProcessRunner.swift"]
        )
        #expect(
            offenders.isEmpty,
            "duplicated synchronous process helpers or hard-coded build paths found in Tests/: \(offenders.sorted().joined(separator: ", "))"
        )
    }

    @Test("user paths are centralized")
    func userPathsAreCentralized() throws {
        let sources = try Self.locate("Sources")
        let offenders = Self.filesContainingRaw(["NSHomeDirectory()"], under: sources)
        #expect(
            offenders.isEmpty,
            "NSHomeDirectory() found in Sources/: \(offenders.sorted().joined(separator: ", "))"
        )
    }

    @Test("temporary directories are centralized")
    func temporaryDirectoriesAreCentralized() throws {
        let tests = try Self.locate("Tests")
        let offenders = Self.filesContainingRaw(
            ["FileManager.default.temporaryDirectory"],
            under: tests,
            ignoring: ["TemporaryDirectory.swift", "M10ReleaseTests.swift"]
        )
        #expect(
            offenders.isEmpty,
            "ad hoc temporaryDirectory usage found in Tests/: \(offenders.sorted().joined(separator: ", "))"
        )
    }

    // MARK: - helpers

    private static func projectRoot() throws -> URL {
        // Walk up from this file until we find Package.swift.
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw POSIXError(.ENOENT)
    }

    private static func locate(_ relative: String) throws -> URL {
        let root = try projectRoot()
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw POSIXError(.ENOENT)
        }
        return url
    }

    private static func fencedBlocks(in url: URL, language: String) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var blocks: [String] = []
        var current: [String]?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current == nil, trimmed == "```\(language)" {
                current = []
            } else if current != nil, trimmed == "```" {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else if current != nil {
                current!.append(line)
            }
        }
        return blocks
    }

    private static func filesContaining(_ needles: [String], under root: URL) -> [String] {
        var offenders: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hit = text.components(separatedBy: "\n").contains { line in
                needles.contains { line.contains("// \($0)") || line.contains("/* \($0)") }
            }
            if hit { offenders.append(url.lastPathComponent) }
        }
        return offenders
    }

    private static func filesContainingRaw(_ needles: [String], under root: URL, ignoring: [String] = []) -> [String] {
        var offenders: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        for case let url as URL in enumerator {
            if ignoring.contains(url.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if needles.contains(where: text.contains(_:)) {
                offenders.append(url.lastPathComponent)
            }
        }
        return offenders
    }
}
