/// Build-time version stamp.
///
/// The committed copy holds dev placeholders. Release builds overwrite this
/// file via `scripts/stamp-version.sh <version>`, which substitutes the git
/// tag and the short commit hash. `scripts/release.sh` and the `release.yml`
/// GitHub workflow both stamp before `swift build -c release`, so the embedded
/// `--version` string matches the tag that produced the binary.
enum BuildInfo {
    static let version = "0.0.0-dev"
    static let commit = "unknown"
}
