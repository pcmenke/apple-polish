import AppKit
import PolishCore

@MainActor
final class MediaStore: ObservableObject {
    enum Phase {
        case idle, loading, loaded
        case failed(message: String, needsAccess: Bool)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var items: [MediaItem] = []

    func reload() {
        phase = .loading
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MessagesLibrary().load() }
            }.value
            switch result {
            case .success(let items):
                self.items = items
                phase = .loaded
            case .failure(let error):
                let denied: Bool
                if case MessagesLibraryError.accessDenied = error { denied = true } else { denied = false }
                phase = .failed(message: error.localizedDescription, needsAccess: denied)
            }
        }
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
