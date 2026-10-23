import AppKit
import Contacts
import PolishCore
import PolishRemote

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
        Task { await trashAndReport(doomed) }
    }

    @discardableResult
    func trashAndReport(_ doomed: [MediaItem]) async -> (done: Int, failed: Int) {
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
        return (outcome.done.count, outcome.failed)
    }

    /// Lets views drop deleted items from their selection.
    @Published private(set) var trashedIDs = Set<String>()

    /// Opens the item's conversation in Messages so it can be deleted there (which is what
    /// removes it from iCloud). Messages cannot be told to scroll to one message, so say where to look.
    func openInMessages(_ item: MediaItem) {
        let when = item.date?.formatted(date: .abbreviated, time: .shortened) ?? "its date"
        if let url = MessagesLink.conversationURL(chatIdentifier: item.chatIdentifier, isGroup: item.isGroup) {
            NSWorkspace.shared.open(url)
            statusMessage = "Opened the thread with \(item.conversation ?? "this contact"). Use its Details (i) button to see the photos and videos, and look for \(when)."
        } else if let messages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            NSWorkspace.shared.open(messages)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.conversation ?? "", forType: .string)
            statusMessage = "Group chats can't be opened directly. Messages is open; find “\(item.conversation ?? "the group")” (name copied), then look for \(when)."
        }
    }

    /// Storage pane of System Settings; Messages > Manage there lists attachments by size and
    /// deletes them through Messages (so the deletion is the one that syncs to iCloud).
    func openMessagesStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
        statusMessage = "In Storage, find Messages and click Manage (or the ⓘ button) to review attachments by size."
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
