import AppKit
import FileProvider
import ADBKit
import os

/// Keeps the adb server alive, follows the device list, and mirrors it into File Provider domains
/// (one domain per authorized phone, identified by its serial).
@Observable
final class DeviceMonitor {
    enum Status: Equatable {
        case starting, adbMissing, serverUnavailable(String), running
    }

    private(set) var status: Status = .starting
    private(set) var devices: [ADBDevice] = []

    private let client = ADBClient()
    private let log = Logger(subsystem: "com.mrbarkan.DriveDroid", category: "DeviceMonitor")
    private var task: Task<Void, Never>?

    init() {
        task = Task { await run() }
    }

    func openInFinder(_ device: ADBDevice) {
        guard let manager = NSFileProviderManager(for: Self.domain(for: device)) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, error in
            if let url { NSWorkspace.shared.open(url) }
            if let error { self.log.error("getUserVisibleURL: \(error)") }
        }
    }

    // MARK: - Loop

    private func run() async {
        guard let adb = ADBLocator.find() else {
            status = .adbMissing
            return
        }
        while !Task.isCancelled {
            try? await ADBLocator.run(adb, ["start-server"])
            do {
                status = .running
                for try await list in client.trackDevices() {
                    devices = list
                    await reconcileDomains()
                }
            } catch {
                log.error("track-devices ended: \(error)")
                status = .serverUnavailable(error.localizedDescription)
                devices = []
                await reconcileDomains()
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private static func domain(for device: ADBDevice) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: .init(device.serial), displayName: device.displayName)
        domain.supportsSyncingTrash = false
        return domain
    }

    /// Adds a domain per ready device, removes domains for unplugged ones.
    private func reconcileDomains() async {
        let ready = devices.filter(\.isReady)
        do {
            let existing = try await NSFileProviderManager.domains()
            for device in ready where !existing.contains(where: { $0.identifier.rawValue == device.serial }) {
                log.info("adding domain for \(device.serial, privacy: .public)")
                try await NSFileProviderManager.add(Self.domain(for: device))
            }
            for domain in existing where !ready.contains(where: { $0.serial == domain.identifier.rawValue }) {
                log.info("removing domain \(domain.identifier.rawValue, privacy: .public)")
                try await NSFileProviderManager.remove(domain)
            }
        } catch {
            log.error("reconcile: \(error)")
        }
    }
}
