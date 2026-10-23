import AppKit
import Contacts
import PolishCore

@MainActor
final class MediaStore: ObservableObject {
    enum Phase {
        case idle, loading, loaded
        case failed(message: String, needsAccess: Bool)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var items: [MediaItem] = []
    /// Bumped on every successful load so views can refresh derived lists cheaply.
    @Published private(set) var version = 0
    @Published private(set) var contactsNote: String?
    @Published var statusMessage: String?

    func reload() {
        phase = .loading
        Task {
            let (names, note) = await Task.detached(priority: .userInitiated) { await ContactsLoader.resolver() }.value
            contactsNote = note
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MessagesLibrary(names: names).load() }
            }.value
            switch result {
            case .success(let items):
                self.items = items
                version += 1
                phase = .loaded
            case .failure(let error):
                let denied: Bool
                if case MessagesLibraryError.accessDenied = error { denied = true } else { denied = false }
                phase = .failed(message: error.localizedDescription, needsAccess: denied)
            }
        }
    }

    /// Moves files to the Trash (recoverable). Messages' database is not touched.
    func trash(_ doomed: [MediaItem]) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (done: Set<String>, failed: Int, bytes: Int64) in
                var done = Set<String>(), failed = 0, bytes: Int64 = 0
                for item in doomed {
                    do {
                        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                        done.insert(item.id); bytes += item.size
                    } catch { failed += 1 }
                }
                return (done, failed, bytes)
            }.value
            items.removeAll { outcome.done.contains($0.id) }
            version += 1
            statusMessage = "Moved \(outcome.done.count) files (\(Formatting.bytes(outcome.bytes))) to the Trash. "
                + "Empty the Trash to free the space."
                + (outcome.failed > 0 ? " \(outcome.failed) could not be moved." : "")
            trashedIDs = outcome.done
        }
    }

    /// Lets views drop deleted items from their selection.
    @Published private(set) var trashedIDs = Set<String>()

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
