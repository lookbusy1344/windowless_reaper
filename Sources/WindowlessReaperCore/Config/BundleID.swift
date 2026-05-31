public struct BundleID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ string: String) {
        value = string
    }

    public var description: String {
        value
    }
}
