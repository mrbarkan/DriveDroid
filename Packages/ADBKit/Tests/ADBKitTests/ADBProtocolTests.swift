import Foundation
import Testing
@testable import ADBKit

@Suite struct ADBProtocolTests {
    @Test func hostRequestIsHexLengthPrefixed() {
        #expect(String(decoding: ADBProtocol.hostRequest("host:version"), as: UTF8.self) == "000chost:version")
    }

    @Test func parsesDeviceListInBothFormats() {
        let text = """
        ZY22ABC123\tdevice
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:3
        0123456789 unauthorized usb:1-2 transport_id:4
        """
        let devices = ADBProtocol.parseDeviceList(text)
        #expect(devices.count == 3)
        #expect(devices[0] == ADBDevice(serial: "ZY22ABC123", state: "device"))
        #expect(devices[1].model == "sdk gphone64 arm64")
        #expect(devices[2].state == "unauthorized" && !devices[2].isReady)
        #expect(ADBProtocol.parseDeviceList("").isEmpty)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(ADBProtocol.shellQuote("it's here") == "'it'\\''s here'")
    }

    @Test func syncRequestLayout() {
        let d = [UInt8](ADBProtocol.syncRequest("LIS2", "/sdcard"))
        #expect(d == Array("LIS2".utf8) + [7, 0, 0, 0] + Array("/sdcard".utf8))
    }

    @Test func parsesDentV2() throws {
        var d = Data("DEN2".utf8)
        func u32(_ v: UInt32) { d.append(ADBProtocol.le(v)) }
        func u64(_ v: UInt64) { d.append(withUnsafeBytes(of: v.littleEndian) { Data($0) }) }
        u32(0)                 // error
        u64(1); u64(2)         // dev, ino
        u32(0o100644)          // mode
        u32(1); u32(0); u32(0) // nlink uid gid
        u64(5_000_000_000)     // size > 4GB
        u64(10); u64(1_700_000_000); u64(11) // atime mtime ctime
        u32(3)                 // namelen
        #expect(d.count == ADBProtocol.dentV2Size)
        let s = try ADBProtocol.parseStatV2(d, hasNameLength: true)
        #expect(s.id == "DEN2")
        #expect(s.size == 5_000_000_000)
        #expect(s.mtime == 1_700_000_000)
        #expect(s.nameLength == 3)
        let entry = SyncEntry(name: "a.b", s)
        #expect(entry.isRegularFile && !entry.isDirectory)
    }

    @Test func shortReadsThrow() {
        #expect(throws: ADBError.self) { try ADBProtocol.parseStatV2(Data("LST2".utf8), hasNameLength: false) }
    }

    @Test func shellHeader() throws {
        let (id, len) = try ADBProtocol.parseShellHeader(Data([3, 1, 0, 0, 0]))
        #expect(id == ADBProtocol.ShellStream.exit.rawValue && len == 1)
    }
}
