import Foundation

/// Pure encoding/decoding for the adb host protocol and the file sync protocol.
/// No I/O here so everything is unit-testable.
/// Reference: packages/modules/adb/{adb.h,file_sync_protocol.h,SERVICES.TXT}
public enum ADBProtocol {
    public static let syncDataMax = 64 * 1024

    // MARK: Host protocol

    /// `host:version` -> "000Chost:version"
    public static func hostRequest(_ service: String) -> Data {
        let payload = Data(service.utf8)
        var data = Data(String(format: "%04x", payload.count).utf8)
        data.append(payload)
        return data
    }

    /// Parses `host:devices-l` / `host:track-devices-l` output.
    public static func parseDeviceList(_ text: String) -> [ADBDevice] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            let model = parts.dropFirst(2)
                .first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return ADBDevice(serial: String(parts[0]), state: String(parts[1]), model: model)
        }
    }

    // MARK: Shell v2 (`shell,v2,raw:<cmd>`)

    public enum ShellStream: UInt8 { case stdin = 0, stdout = 1, stderr = 2, exit = 3, closeStdin = 4, windowSize = 5 }

    /// Header is 1 byte id + u32 LE payload length.
    public static let shellHeaderSize = 5
    public static func parseShellHeader(_ data: Data) throws -> (id: UInt8, length: Int) {
        var r = ByteReader(data)
        let id = try r.read(UInt8.self)
        return (id, Int(try r.read(UInt32.self)))
    }

    /// POSIX single-quote escaping for use inside `shell:` commands.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Sync protocol

    public static let statV2Size = 72   // sync_stat_v2
    public static let dentV2Size = 76   // sync_dent_v2 (stat_v2 + namelen)

    /// `id` is a 4-char ASCII tag (LIST, LIS2, STAT, LST2, RECV, SEND, DATA, DONE, QUIT ...).
    public static func syncRequest(_ id: String, _ path: String) -> Data {
        var d = Data(id.utf8)
        d.append(le(UInt32(path.utf8.count)))
        d.append(contentsOf: path.utf8)
        return d
    }

    public static func syncMessage(_ id: String, _ value: UInt32) -> Data {
        var d = Data(id.utf8)
        d.append(le(value))
        return d
    }

    public static func le(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    /// Decoded `sync_stat_v2` / `sync_dent_v2` body. `name` is filled from the DEN2 trailer or by the caller.
    public struct StatV2: Sendable {
        public var id: String
        public var error: UInt32
        public var mode: UInt32
        public var size: UInt64
        public var mtime: Int64
        public var nameLength: Int   // dent only
    }

    public static func parseStatV2(_ data: Data, hasNameLength: Bool) throws -> StatV2 {
        var r = ByteReader(data)
        let id = try r.tag()
        let error = try r.read(UInt32.self)
        _ = try r.read(UInt64.self) // dev
        _ = try r.read(UInt64.self) // ino
        let mode = try r.read(UInt32.self)
        _ = try r.read(UInt32.self) // nlink
        _ = try r.read(UInt32.self) // uid
        _ = try r.read(UInt32.self) // gid
        let size = try r.read(UInt64.self)
        _ = try r.read(Int64.self)  // atime
        let mtime = try r.read(Int64.self)
        _ = try r.read(Int64.self)  // ctime
        let nameLength = hasNameLength ? Int(try r.read(UInt32.self)) : 0
        return StatV2(id: id, error: error, mode: mode, size: size, mtime: mtime, nameLength: nameLength)
    }

    /// `sync_data` / `sync_status`: 4-char tag + u32.
    public static func parseSyncHeader(_ data: Data) throws -> (id: String, value: UInt32) {
        var r = ByteReader(data)
        return (try r.tag(), try r.read(UInt32.self))
    }
}

public struct ADBDevice: Sendable, Hashable, Identifiable {
    public var serial: String
    /// device, unauthorized, offline, recovery, ...
    public var state: String
    public var model: String?
    public var id: String { serial }
    public var isReady: Bool { state == "device" }
    public var displayName: String { model ?? serial }

    public init(serial: String, state: String, model: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
    }
}

/// A directory entry or stat result from the sync service.
public struct SyncEntry: Sendable, Hashable {
    public var name: String
    public var mode: UInt32
    public var size: UInt64
    public var mtime: Date

    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isRegularFile: Bool { mode & 0o170000 == 0o100000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }

    public init(name: String, mode: UInt32, size: UInt64, mtime: Date) {
        self.name = name
        self.mode = mode
        self.size = size
        self.mtime = mtime
    }

    init(name: String, _ s: ADBProtocol.StatV2) {
        self.init(name: name, mode: s.mode, size: s.size, mtime: Date(timeIntervalSince1970: TimeInterval(s.mtime)))
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard offset + n <= bytes.count else { throw ADBError.protocolError("short read (\(bytes.count) bytes)") }
        var v: T = 0
        for i in 0..<n { v |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
        offset += n
        return v
    }

    mutating func tag() throws -> String {
        guard offset + 4 <= bytes.count else { throw ADBError.protocolError("short read") }
        defer { offset += 4 }
        return String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }
}
