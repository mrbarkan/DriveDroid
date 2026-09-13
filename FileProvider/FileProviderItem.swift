import FileProvider
import UniformTypeIdentifiers
import ADBKit

/// Paths relative to the phone's shared storage double as item identifiers ("/" is the root container).
enum ItemPath {
    static let remoteRoot = "/sdcard"

    static func identifier(for path: String) -> NSFileProviderItemIdentifier {
        path == "/" ? .rootContainer : NSFileProviderItemIdentifier(path)
    }

    static func path(for identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "/" : identifier.rawValue
    }

    static func remote(_ path: String) -> String {
        path == "/" ? remoteRoot : remoteRoot + path
    }

    static func child(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}

final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let path: String
    let entry: SyncEntry

    init(path: String, entry: SyncEntry) {
        self.path = path
        self.entry = entry
    }

    static let root = FileProviderItem(path: "/", entry: SyncEntry(name: "Android", mode: 0o040755, size: 0, mtime: .distantPast))

    var itemIdentifier: NSFileProviderItemIdentifier { ItemPath.identifier(for: path) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        path == "/" ? .rootContainer : ItemPath.identifier(for: ItemPath.parent(path))
    }
    var filename: String { entry.name }

    var contentType: UTType {
        if entry.isDirectory { return .folder }
        return UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        entry.isDirectory
            ? [.allowsAddingSubItems, .allowsContentEnumerating, .allowsReading, .allowsDeleting, .allowsRenaming, .allowsReparenting]
            : [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
    }

    var itemVersion: NSFileProviderItemVersion {
        let v = Data("\(entry.size)-\(Int64(entry.mtime.timeIntervalSince1970))".utf8)
        return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
    }

    var documentSize: NSNumber? { entry.isDirectory ? nil : NSNumber(value: entry.size) }
    var contentModificationDate: Date? { entry.mtime }
}
