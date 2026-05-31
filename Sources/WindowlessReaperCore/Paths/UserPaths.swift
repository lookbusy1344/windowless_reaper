import Foundation

public struct UserPaths: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var configURL: URL {
        homeDirectory.appendingPathComponent(".config/windowless-reaper/config.toml")
    }

    public func launchAgentPlistURL(label: String) -> URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public func logURL(relativePath: String) -> URL {
        homeDirectory.appendingPathComponent(relativePath)
    }
}
