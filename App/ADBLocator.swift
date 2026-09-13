import Foundation

enum ADBLocator {
    /// Looks in the bundle first (so a build can ship platform-tools), then the usual install spots.
    nonisolated static func find() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "adb", ofType: nil) { candidates.append(bundled) }
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] { candidates.append("\(home)/platform-tools/adb") }
        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in c.resume() }
            do { try process.run() } catch { c.resume(throwing: error) }
        }
    }
}
