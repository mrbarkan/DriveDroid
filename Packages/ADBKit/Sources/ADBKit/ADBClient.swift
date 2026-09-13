import Foundation

/// High-level entry points. Each call opens its own connection to the adb server.
public struct ADBClient: Sendable {
    public var port: UInt16

    public init(port: UInt16 = ADBConnection.defaultPort) { self.port = port }

    public func serverVersion() async throws -> Int {
        let c = try await ADBConnection.connect(port: port)
        defer { c.close() }
        try await c.request("host:version")
        return Int(try await c.readLengthPrefixed(), radix: 16) ?? 0
    }

    public func devices() async throws -> [ADBDevice] {
        let c = try await ADBConnection.connect(port: port)
        defer { c.close() }
        try await c.request("host:devices-l")
        return ADBProtocol.parseDeviceList(try await c.readLengthPrefixed())
    }

    /// Yields the full device list every time it changes. Finishes with an error when the server goes away.
    public func trackDevices() -> AsyncThrowingStream<[ADBDevice], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let c = try await ADBConnection.connect(port: port)
                    defer { c.close() }
                    try await c.request("host:track-devices-l")
                    while true {
                        continuation.yield(ADBProtocol.parseDeviceList(try await c.readLengthPrefixed()))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens a connection bound to `serial` and starts `service` (e.g. "sync:", "shell,v2,raw:ls").
    public func open(serial: String, service: String) async throws -> ADBConnection {
        let c = try await ADBConnection.connect(port: port)
        do {
            try await c.request("host:transport:\(serial)")
            try await c.request(service)
        } catch {
            c.close()
            throw error
        }
        return c
    }

    public struct ShellResult: Sendable {
        public var exitCode: Int32
        public var stdout: Data
        public var stderr: Data
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs `command` through `sh -c` on the device (shell v2, so we get a real exit code).
    /// Quote arguments with `ADBProtocol.shellQuote`.
    public func shell(serial: String, _ command: String) async throws -> ShellResult {
        let c = try await open(serial: serial, service: "shell,v2,raw:\(command)")
        defer { c.close() }
        var out = Data(), err = Data()
        while true {
            let (id, len) = try await ADBProtocol.parseShellHeader(c.receive(exactly: ADBProtocol.shellHeaderSize))
            let payload = try await c.receive(exactly: len)
            switch ADBProtocol.ShellStream(rawValue: id) {
            case .stdout: out.append(payload)
            case .stderr: err.append(payload)
            case .exit: return ShellResult(exitCode: Int32(payload.first ?? 255), stdout: out, stderr: err)
            default: break
            }
        }
    }

    /// Runs `command` and throws `ADBError.commandFailed` on non-zero exit.
    @discardableResult
    public func run(serial: String, _ command: String) async throws -> String {
        let r = try await shell(serial: serial, command)
        guard r.exitCode == 0 else { throw ADBError.commandFailed(exitCode: r.exitCode, stderr: r.stderrText) }
        return r.stdoutText
    }

    public func sync(serial: String) async throws -> ADBSyncSession {
        ADBSyncSession(connection: try await open(serial: serial, service: "sync:"))
    }
}
