import Foundation

public enum ADBError: Error, LocalizedError, Sendable {
    case connectionClosed
    case protocolError(String)
    /// The adb server or the device answered FAIL with this message.
    case serverFailure(String)
    /// A `shell` command exited non-zero; payload is stderr.
    case commandFailed(exitCode: Int32, stderr: String)
    case remoteError(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: "adb connection closed"
        case .protocolError(let s): "adb protocol error: \(s)"
        case .serverFailure(let s): "adb: \(s)"
        case .commandFailed(let code, let err): "command failed (\(code)): \(err)"
        case .remoteError(let e): "remote error: \(String(cString: strerror(e)))"
        }
    }
}
