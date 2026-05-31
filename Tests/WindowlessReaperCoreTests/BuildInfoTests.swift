import Testing
@testable import wreaper

/// The release version + commit are stamped into `BuildInfo` at build time
/// (see `scripts/stamp-version.sh`). These checks pin the *wiring* — not the
/// literal values, which differ between a dev checkout and a stamped release
/// build — so they stay green under both.
@Suite("Build info", .timeLimit(.minutes(1)))
struct BuildInfoTests {
    @Test("--version reflects the stamped version and commit")
    func versionStringIsWired() {
        #expect(Wreaper.configuration.version == "\(BuildInfo.version) (\(BuildInfo.commit))")
    }

    @Test("stamped fields are never empty")
    func fieldsArePresent() {
        #expect(!BuildInfo.version.isEmpty)
        #expect(!BuildInfo.commit.isEmpty)
    }
}
