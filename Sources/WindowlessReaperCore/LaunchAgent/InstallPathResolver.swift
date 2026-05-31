/// Resolves the binary install path for the LaunchAgent plist.
///
/// Priority: explicit `--prefix` flag wins; otherwise `HOMEBREW_PREFIX/bin` if
/// set (Apple Silicon Homebrew is `/opt/homebrew`); finally `/usr/local/bin`.
/// The resolved path is what ends up in the plist's `ProgramArguments`, so
/// it must point at a binary that actually exists — `wreaper install` checks
/// before writing the plist.
public enum InstallPathResolver {
    public static let fallbackPrefix = "/usr/local"
    public static let binaryName = "wreaper"

    public static func resolve(prefix: String?, homebrewPrefix: String?) -> String {
        let chosenPrefix: String =
            if let prefix, !prefix.isEmpty {
                prefix
            } else if let homebrew = homebrewPrefix, !homebrew.isEmpty {
                homebrew
            } else {
                fallbackPrefix
            }
        return "\(chosenPrefix)/bin/\(binaryName)"
    }
}
