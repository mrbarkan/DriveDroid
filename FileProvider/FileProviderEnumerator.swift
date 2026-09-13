import FileProvider
import ADBKit

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    /// nil enumerates the (always empty) working set.
    private let path: String?
    private let client: ADBClient
    private let serial: String

    init(path: String?, client: ADBClient, serial: String) {
        self.path = path
        self.client = client
        self.serial = serial
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let path else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        nonisolated(unsafe) let observer = observer
        Task {
            do {
                let session = try await client.sync(serial: serial)
                defer { session.close() }
                let remote = ItemPath.remote(path)
                guard let entry = try await session.stat(remote) else { throw NSFileProviderError(.noSuchItem) }
                let items: [FileProviderItem] = if entry.isDirectory {
                    try await session.list(remote).map { FileProviderItem(path: ItemPath.child(path, $0.name), entry: $0) }
                } else {
                    [FileProviderItem(path: path, entry: entry)]
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    // ponytail: no change journal on the phone, so every change request forces a full re-enumeration.
    // Fine for USB; add a real anchor if it ever gets chatty.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if path == nil {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8)))
    }
}
