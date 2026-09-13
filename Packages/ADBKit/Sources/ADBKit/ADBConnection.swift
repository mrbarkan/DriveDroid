import Foundation
import Network
import Synchronization

/// One TCP connection to the local adb server. Speaks the framed host protocol.
public actor ADBConnection {
    public static let defaultPort: UInt16 = 5037

    private nonisolated let connection: NWConnection

    private init(connection: NWConnection) { self.connection = connection }

    public static func connect(host: String = "127.0.0.1", port: UInt16 = defaultPort) async throws -> ADBConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ADBError.protocolError("bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = Mutex<CheckedContinuation<Void, Error>?>(nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            gate.withLock { $0 = c }
            conn.stateUpdateHandler = { state in
                let pending = gate.withLock { c in
                    let p = c
                    c = nil
                    return p
                }
                switch state {
                case .ready: pending?.resume()
                case .failed(let e): pending?.resume(throwing: e)
                case .cancelled: pending?.resume(throwing: ADBError.connectionClosed)
                default: gate.withLock { $0 = pending }
                }
            }
            conn.start(queue: .global())
        }
        conn.stateUpdateHandler = nil
        return ADBConnection(connection: conn)
    }

    public nonisolated func close() { connection.cancel() }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    public func receive(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { c.resume(throwing: error); return }
                    guard let data, data.count == count else { c.resume(throwing: ADBError.connectionClosed); return }
                    c.resume(returning: data)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    // MARK: Host protocol helpers

    /// Sends a length-prefixed service request and waits for OKAY (throws on FAIL).
    public func request(_ service: String) async throws {
        try await send(ADBProtocol.hostRequest(service))
        try await expectOkay()
    }

    public func expectOkay() async throws {
        let status = String(decoding: try await receive(exactly: 4), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL": throw ADBError.serverFailure(try await readLengthPrefixed())
        default: throw ADBError.protocolError("unexpected status \(status)")
        }
    }

    /// Reads a 4-hex-digit length followed by that many bytes.
    public func readLengthPrefixed() async throws -> String {
        let hex = String(decoding: try await receive(exactly: 4), as: UTF8.self)
        guard let len = Int(hex, radix: 16) else { throw ADBError.protocolError("bad length \(hex)") }
        return String(decoding: try await receive(exactly: len), as: UTF8.self)
    }
}
