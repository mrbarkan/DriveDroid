import FileProvider
import UniformTypeIdentifiers
import ADBKit
import os

/// One instance per File Provider domain; the domain identifier is the phone's adb serial.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let serial: String
    private let client = ADBClient()
    private let log = Logger(subsystem: "com.mrbarkan.DriveDroid", category: "FileProvider")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.serial = domain.identifier.rawValue
        super.init()
    }

    func invalidate() {}

    // MARK: - Reads

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress()
        nonisolated(unsafe) let completionHandler = completionHandler
        let task = Task {
            do { completionHandler(try await fetchItem(ItemPath.path(for: identifier)), nil) }
            catch { completionHandler(nil, error) }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress()
        nonisolated(unsafe) let completionHandler = completionHandler
        let task = Task {
            do {
                let path = ItemPath.path(for: itemIdentifier)
                let session = try await client.sync(serial: serial)
                defer { session.close() }
                guard let entry = try await session.stat(ItemPath.remote(path)) else { throw NSFileProviderError(.noSuchItem) }
                progress.totalUnitCount = Int64(entry.size)
                let url = temporaryDirectory.appending(path: UUID().uuidString)
                try await session.pull(ItemPath.remote(path), to: url) { progress.completedUnitCount = $0 }
                completionHandler(url, FileProviderItem(path: path, entry: entry), nil)
            } catch {
                log.error("fetchContents \(itemIdentifier.rawValue, privacy: .public): \(error)")
                completionHandler(nil, nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet: FileProviderEnumerator(path: nil, client: client, serial: serial)
        case .trashContainer: throw NSFileProviderError(.noSuchItem)
        default: FileProviderEnumerator(path: ItemPath.path(for: containerItemIdentifier), client: client, serial: serial)
        }
    }

    // MARK: - Writes

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress()
        nonisolated(unsafe) let completionHandler = completionHandler
        nonisolated(unsafe) let itemTemplate = itemTemplate
        let task = Task {
            do {
                let path = ItemPath.child(ItemPath.path(for: itemTemplate.parentItemIdentifier), itemTemplate.filename)
                let remote = ItemPath.remote(path)
                if itemTemplate.contentType == .folder {
                    try await client.run(serial: serial, "mkdir -p \(ADBProtocol.shellQuote(remote))")
                } else if let url {
                    try await push(url, to: remote, mtime: itemTemplate.contentModificationDate ?? nil, progress: progress)
                } else {
                    try await client.run(serial: serial, "touch \(ADBProtocol.shellQuote(remote))")
                }
                completionHandler(try await fetchItem(path), [], false, nil)
            } catch {
                log.error("createItem \(itemTemplate.filename, privacy: .public): \(error)")
                completionHandler(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // ponytail: identifiers are paths, so a rename/move returns an item with a new identifier and we nudge
    // both parents to re-enumerate. Stable IDs would need an inode map; add one if Finder gets confused.
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress()
        nonisolated(unsafe) let completionHandler = completionHandler
        nonisolated(unsafe) let item = item
        let task = Task {
            do {
                let oldPath = ItemPath.path(for: item.itemIdentifier)
                guard oldPath != "/" else { throw NSFileProviderError(.noSuchItem) }
                var path = oldPath
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    path = ItemPath.child(ItemPath.path(for: item.parentItemIdentifier), item.filename)
                    if path != oldPath {
                        try await client.run(serial: serial, "mv \(ADBProtocol.shellQuote(ItemPath.remote(oldPath))) \(ADBProtocol.shellQuote(ItemPath.remote(path)))")
                    }
                }
                if changedFields.contains(.contents), let newContents {
                    try await push(newContents, to: ItemPath.remote(path), mtime: item.contentModificationDate ?? nil, progress: progress)
                }
                completionHandler(try await fetchItem(path), [], false, nil)
                if path != oldPath { signal(parentsOf: [oldPath, path]) }
            } catch {
                log.error("modifyItem \(item.itemIdentifier.rawValue, privacy: .public): \(error)")
                completionHandler(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress()
        nonisolated(unsafe) let completionHandler = completionHandler
        let task = Task {
            do {
                let path = ItemPath.path(for: identifier)
                guard path != "/" else { throw NSFileProviderError(.noSuchItem) }
                try await client.run(serial: serial, "rm -rf \(ADBProtocol.shellQuote(ItemPath.remote(path)))")
                completionHandler(nil)
            } catch {
                log.error("deleteItem \(identifier.rawValue, privacy: .public): \(error)")
                completionHandler(error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Helpers

    private func fetchItem(_ path: String) async throws -> FileProviderItem {
        if path == "/" { return .root }
        let session = try await client.sync(serial: serial)
        defer { session.close() }
        guard let entry = try await session.stat(ItemPath.remote(path)) else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderItem(path: path, entry: entry)
    }

    private func push(_ url: URL, to remote: String, mtime: Date?, progress: Progress) async throws {
        let session = try await client.sync(serial: serial)
        defer { session.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        progress.totalUnitCount = Int64(size)
        try await session.push(url, to: remote, mtime: mtime ?? Date()) { progress.completedUnitCount = $0 }
    }

    private func signal(parentsOf paths: [String]) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        for parent in Set(paths.map(ItemPath.parent)) {
            manager.signalEnumerator(for: ItemPath.identifier(for: parent)) { _ in }
        }
    }

    private var temporaryDirectory: URL {
        (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()).flatMap { $0 } ?? FileManager.default.temporaryDirectory
    }
}
