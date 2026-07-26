import Foundation

public enum DeviceState: String, Sendable, Equatable {
    case device
    case unauthorized
    case offline
    case unknown

    init(raw: String) {
        self = DeviceState(rawValue: raw) ?? .unknown
    }
}

public struct ADBDevice: Sendable, Equatable, Identifiable {
    public let serial: String
    public let state: DeviceState
    public var id: String { serial }

    public init(serial: String, state: DeviceState) {
        self.serial = serial
        self.state = state
    }

    /// Each line is "<serial>\t<state>". Malformed lines are skipped rather
    /// than failing the whole list — one odd entry should not blank the sidebar.
    public static func parseList(_ payload: Data) -> [ADBDevice] {
        String(decoding: payload, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return ADBDevice(
                    serial: String(parts[0]).trimmingCharacters(in: .whitespaces),
                    state: DeviceState(raw: String(parts[1]).trimmingCharacters(in: .whitespaces))
                )
            }
    }
}
