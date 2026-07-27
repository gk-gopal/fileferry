import Foundation

public enum ADBError: Error, Equatable, Sendable {
    case requestTooLong
    case malformedResponse(String)
    case malformedLength(String)
    case remote(String)
    case connectionClosed
    case binaryNotFound
    case binaryTooOld(found: String, required: String)
    case serverUnavailable(String)
    case deviceNotFound(String)
    case unsupportedFeature(String)
    case transferFailed(path: String, reason: String)
}

extension ADBError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestTooLong:
            "The request was too long for the adb protocol."
        case .malformedResponse(let got):
            "Unexpected reply from the adb server: \(got)"
        case .malformedLength(let got):
            "The adb server sent a length field that isn't hexadecimal: \(got)"
        case .remote(let message):
            message
        case .connectionClosed:
            "The connection to the adb server closed unexpectedly."
        case .binaryNotFound:
            "Couldn't find adb. Install it with: brew install --cask android-platform-tools"
        case .binaryTooOld(let found, let required):
            "adb \(found) is too old — FileFerry needs \(required) or newer."
        case .serverUnavailable(let detail):
            "Couldn't reach the adb server. \(detail)"
        case .deviceNotFound(let serial):
            "Device \(serial) isn't connected."
        case .unsupportedFeature(let feature):
            "This device doesn't support \(feature)."
        case .transferFailed(let path, let reason):
            "Couldn't transfer \(path): \(reason)"
        }
    }
}
