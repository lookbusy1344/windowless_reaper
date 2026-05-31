import Logging
import Synchronization

/// Minimal `LogHandler` that records every formatted message into a
/// shared sink so tests can assert on log emission without scraping stderr.
public struct RecordingLogHandler: LogHandler {
    public final class Sink: @unchecked Sendable {
        private let storage = Mutex<[String]>([])

        public init() {}

        public func append(_ line: String) {
            storage.withLock { $0.append(line) }
        }

        public func messages() -> [String] {
            storage.withLock { $0 }
        }
    }

    public let sink: Sink
    public var logLevel: Logger.Level = .trace
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?

    public init(sink: Sink) {
        self.sink = sink
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        sink.append("\(event.level) \(event.message)")
    }
}
