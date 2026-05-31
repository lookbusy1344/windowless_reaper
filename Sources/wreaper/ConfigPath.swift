import ArgumentParser
import Foundation
import WindowlessReaperCore

enum ConfigPath {
    static func defaultURL() -> URL {
        UserPaths().configURL
    }

    static func resolve(override: String?) -> URL {
        override.map { URL(fileURLWithPath: $0) } ?? defaultURL()
    }

    /// Load with a CLI-friendly error: parse errors and missing files are
    /// surfaced as `ValidationError` (ArgumentParser prints them and exits
    /// with code 1) rather than untyped Swift errors.
    static func load(from url: URL) throws -> Config {
        do {
            return try ConfigLoader.load(from: url)
        } catch ConfigError.fileNotFound(let path) {
            throw ValidationError("No config at \(path). Run 'wreaper config init' to create one.")
        } catch let error as ConfigError {
            throw ValidationError(error.userFacingMessage)
        }
    }
}
