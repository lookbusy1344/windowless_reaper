import Foundation

final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init(prefix: String = "wreaper-test") throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        url = path
    }

    func child(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
