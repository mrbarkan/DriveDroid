import SwiftUI
import FileProvider

@main
struct DriveDroidApp: App {
    @State private var monitor = DeviceMonitor()

    var body: some Scene {
        MenuBarExtra("DriveDroid", systemImage: monitor.devices.contains(where: \.isReady) ? "smartphone" : "smartphone.slash") {
            StatusMenu(monitor: monitor)
        }
    }
}

struct StatusMenu: View {
    let monitor: DeviceMonitor

    var body: some View {
        switch monitor.status {
        case .starting:
            Text("Starting adb…")
        case .adbMissing:
            Text("adb not found")
            Button("How to install adb…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/mrbarkan/DriveDroid#install-adb")!)
            }
        case .serverUnavailable(let message):
            Text("adb server unavailable: \(message)")
        case .running:
            if monitor.devices.isEmpty {
                Text("No phone connected")
            }
            ForEach(monitor.devices) { device in
                switch device.state {
                case "device":
                    Button("\(device.displayName) — Open in Finder") { monitor.openInFinder(device) }
                case "unauthorized":
                    Text("\(device.displayName) — tap Allow on the phone")
                default:
                    Text("\(device.displayName) — \(device.state)")
                }
            }
        }
        Divider()
        Button("Quit DriveDroid") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
