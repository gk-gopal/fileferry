import Foundation

/// Streams the device list. The adb server pushes a fresh frame on every
/// connect or disconnect, so nothing here polls — which is what lets the UI
/// react the instant a cable is plugged in.
public struct DeviceTracker: Sendable {
    private let server: ADBServer

    public init(server: ADBServer) {
        self.server = server
    }

    public func devices() -> AsyncThrowingStream<[ADBDevice], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await server.request("host:track-devices")
                    while !Task.isCancelled {
                        let payload = try await readHexPayload(from: stream)
                        continuation.yield(ADBDevice.parseList(payload))
                    }
                    await stream.close()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
