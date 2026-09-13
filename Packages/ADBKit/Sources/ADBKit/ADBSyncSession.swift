import Foundation

/// A `sync:` session on one device: stat / list / pull / push.
/// Uses the v2 stat and list messages (64-bit sizes; Android 8+) and v1 RECV/SEND (universal).
public final class ADBSyncSession: Sendable {
    private let connection: ADBConnection

    init(connection: ADBConnection) { self.connection = connection }

    /// Drops the connection without a QUIT handshake. Safe at any point.
    public func close() { connection.close() }

    /// lstat. Returns nil if the path does not exist.
    public func stat(_ path: String) async throws -> SyncEntry? {
        try await connection.send(ADBProtocol.syncRequest("LST2", path))
        let s = try await ADBProtocol.parseStatV2(connection.receive(exactly: ADBProtocol.statV2Size), hasNameLength: false)
        guard s.id == "LST2" || s.id == "STA2" else { throw try await unexpected(s.id) }
        if s.error != 0 {
            if s.error == UInt32(ENOENT) { return nil }
            throw ADBError.remoteError(errno: Int32(s.error))
        }
        let name = path.split(separator: "/").last.map(String.init) ?? "/"
        return SyncEntry(name: name, s)
    }

    public func list(_ directory: String) async throws -> [SyncEntry] {
        try await connection.send(ADBProtocol.syncRequest("LIS2", directory))
        var entries: [SyncEntry] = []
        while true {
            let s = try await ADBProtocol.parseStatV2(connection.receive(exactly: ADBProtocol.dentV2Size), hasNameLength: true)
            if s.id == "DONE" {
                if s.error != 0 { throw ADBError.remoteError(errno: Int32(s.error)) }
                return entries
            }
            guard s.id == "DEN2" else { throw try await unexpected(s.id) }
            let name = String(decoding: try await connection.receive(exactly: s.nameLength), as: UTF8.self)
            if name == "." || name == ".." || s.error != 0 { continue }
            entries.append(SyncEntry(name: name, s))
        }
    }

    /// Streams `path` into a new file at `destination` (overwritten).
    public func pull(_ path: String, to destination: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        try await connection.send(ADBProtocol.syncRequest("RECV", path))
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: Int64 = 0
        while true {
            let (id, value) = try await ADBProtocol.parseSyncHeader(connection.receive(exactly: 8))
            switch id {
            case "DATA":
                let chunk = try await connection.receive(exactly: Int(value))
                try handle.write(contentsOf: chunk)
                received += Int64(chunk.count)
                progress?(received)
            case "DONE":
                return
            case "FAIL":
                throw ADBError.serverFailure(String(decoding: try await connection.receive(exactly: Int(value)), as: UTF8.self))
            default:
                throw ADBError.protocolError("unexpected sync id \(id)")
            }
        }
    }

    /// Uploads the file at `source` to `path`, creating or overwriting it.
    public func push(_ source: URL, to path: String, mode: UInt32 = 0o644, mtime: Date = Date(), progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try await connection.send(ADBProtocol.syncRequest("SEND", "\(path),\(mode)"))
        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: ADBProtocol.syncDataMax), !chunk.isEmpty {
            try await connection.send(ADBProtocol.syncMessage("DATA", UInt32(chunk.count)) + chunk)
            sent += Int64(chunk.count)
            progress?(sent)
        }
        try await connection.send(ADBProtocol.syncMessage("DONE", UInt32(clamping: Int64(mtime.timeIntervalSince1970))))
        let (id, value) = try await ADBProtocol.parseSyncHeader(connection.receive(exactly: 8))
        switch id {
        case "OKAY": return
        case "FAIL": throw ADBError.serverFailure(String(decoding: try await connection.receive(exactly: Int(value)), as: UTF8.self))
        default: throw ADBError.protocolError("unexpected sync id \(id)")
        }
    }

    public func quit() async {
        try? await connection.send(ADBProtocol.syncMessage("QUIT", 0))
        close()
    }

    private func unexpected(_ id: String) async throws -> ADBError {
        if id == "FAIL" {
            // FAIL is `sync_status`: we already consumed the tag + msglen as part of a larger struct read, so the
            // message text is lost; report what we can.
            return ADBError.serverFailure("sync request failed")
        }
        return ADBError.protocolError("unexpected sync id \(id)")
    }
}
