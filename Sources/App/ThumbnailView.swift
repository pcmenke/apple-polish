import AppKit
import PolishCore
import SwiftUI

struct ThumbnailView: View {
    let item: MediaItem
    @State private var state: ThumbnailResult?

    init(item: MediaItem) {
        self.item = item
        _state = State(initialValue: ThumbnailService.shared.resolved(item))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            switch state {
            case .image(let image):
                Image(nsImage: image).resizable().scaledToFill()
            case .unavailable(let reason):
                VStack(spacing: 6) {
                    Image(systemName: item.kind == .video ? "video.slash" : "photo.badge.exclamationmark")
                        .font(.title2)
                    Text(reason).font(.caption2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary).padding(8)
            case .cancelled, .none:
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.id) {
            if let ready = ThumbnailService.shared.resolved(item) { state = ready; return }
            state = nil
            let result = await ThumbnailService.shared.result(for: item)
            if case .cancelled = result { return }  // scrolled away before it started
            state = result
        }
    }
}
