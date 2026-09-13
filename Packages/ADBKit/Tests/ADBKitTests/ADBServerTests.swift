import Foundation
import Testing
@testable import ADBKit

/// Talks to a real adb server on 127.0.0.1:5037 if one is running; skipped otherwise.
@Suite struct ADBServerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADB_SERVER_TESTS"] != nil))
    func versionAndDeviceList() async throws {
        let client = ADBClient()
        #expect(try await client.serverVersion() > 0)
        _ = try await client.devices()
        var iterator = client.trackDevices().makeAsyncIterator()
        _ = try await iterator.next() // first snapshot arrives immediately
    }
}
