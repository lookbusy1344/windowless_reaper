public enum WindowState: Sendable, Equatable, CustomStringConvertible {
    case none
    case minimised
    case visible
    case unknown

    public var description: String {
        switch self {
        case .none: "none"
        case .minimised: "minimised"
        case .visible: "visible"
        case .unknown: "unknown"
        }
    }
}
