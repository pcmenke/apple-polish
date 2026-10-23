import PolishRemote
import SwiftUI

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

private enum Source: Hashable {
    case all, unplayable
    case conversation(String)

    var title: String {
        switch self {
        case .all: return "All media"
        case .unplayable: return "Unplayable video data"
        case .conversation(let name): return name
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject var model: ViewerModel

    private var readable: [RemoteItem] { model.items.filter(\.isReadable) }

    var body: some View {
        List {
            Section("Library") {
                row(.all, items: readable)
                row(.unplayable, items: model.items.filter { !$0.isReadable })
            }
            Section("Conversations") {
                let groups = Dictionary(grouping: readable.filter(\.isLinked), by: { $0.conversation ?? "" })
                ForEach(groups.keys.sorted { size(groups[$0]!) > size(groups[$1]!) }, id: \.self) { name in
                    row(.conversation(name), items: groups[name]!)
                }
            }
        }
        .navigationTitle("Apple Polish")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Disconnect") { model.disconnect() } }
            ToolbarItem(placement: .topBarTrailing) { Button("Reload", systemImage: "arrow.clockwise") { Task { await model.reload() } } }
        }
        .refreshable { await model.reload() }
        .navigationDestination(for: Source.self) { source in
            ItemsGridView(source: source)
        }
    }

    private func size(_ items: [RemoteItem]) -> Int64 { items.reduce(0) { $0 + $1.size } }

    private func row(_ source: Source, items: [RemoteItem]) -> some View {
        NavigationLink(value: source) {
            VStack(alignment: .leading) {
                Text(source.title).lineLimit(1)
                Text("\(items.count) files, \(bytes(size(items)))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ItemsGridView: View {
    @EnvironmentObject var model: ViewerModel
    fileprivate let source: Source
    @State private var onlyVideos = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmTrash = false
    @State private var detail: RemoteItem?

    private var items: [RemoteItem] {
        model.items.filter { item in
            switch source {
            case .all: return item.isReadable
            case .unplayable: return !item.isReadable
            case .conversation(let name): return item.isReadable && item.conversation == name
            }
        }
        .filter { !onlyVideos || $0.isVideo }
        .sorted { $0.size > $1.size }
    }

    var body: some View {
        let items = items
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    cell(item)
                        .onAppear { prefetch(items, after: index) }
                        .onTapGesture { tap(item) }
                        .contextMenu { menu(item) }
                }
            }
            .padding(6)
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Videos only", isOn: $onlyVideos)
                    Button(selecting ? "Done selecting" : "Select") { selecting.toggle(); if !selecting { selection.removeAll() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if selecting {
                    Text("\(selection.count) selected, \(bytes(items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }))")
                        .font(.footnote)
                    Spacer()
                    Button("Trash on Mac…", role: .destructive) { confirmTrash = true }.disabled(selection.isEmpty)
                }
            }
        }
        .confirmationDialog("Move \(selection.count) file\(selection.count == 1 ? "" : "s") to the Mac's Trash?",
                            isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                let ids = Array(selection)
                selection.removeAll(); selecting = false
                Task { await model.trashOnMac(ids) }
            }
        } message: {
            Text("They go to the Trash on the Mac, so they can be put back. This does not delete anything from iCloud or Messages; to do that, open the conversation in Messages and delete there.")
        }
        .sheet(item: $detail) { item in DetailView(item: item) }
        .onDisappear { Task { await model.thumbnails.dropPrefetch() } }
    }

    private func tap(_ item: RemoteItem) {
        if selecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            detail = item
        }
    }

    private func prefetch(_ items: [RemoteItem], after index: Int) {
        let upcoming = items[min(items.count, index + 1) ..< min(items.count, index + 25)]
        for item in upcoming where model.thumbnails.cached(item.id) == nil {
            Task(priority: .low) { _ = await model.thumbnails.image(for: item.id, priority: .prefetch) }
        }
    }

    @ViewBuilder private func menu(_ item: RemoteItem) -> some View {
        if item.isLinked { Button("Open Conversation in Messages", systemImage: "message") { model.openConversation(item) } }
        Button("Move to Mac's Trash…", systemImage: "trash", role: .destructive) {
            selection = [item.id]; confirmTrash = true
        }
    }

    private func cell(_ item: RemoteItem) -> some View {
        ThumbnailCell(item: item)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Text(bytes(item.size)).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo { Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).padding(5).shadow(radius: 2) }
            }
            .overlay(alignment: .topLeading) {
                if selecting {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white, selection.contains(item.id) ? .blue : .gray).padding(5)
                }
            }
    }
}

struct ThumbnailCell: View {
    @EnvironmentObject var model: ViewerModel
    let item: RemoteItem
    @State private var image: UIImage?
    @State private var failed = false

    init(item: RemoteItem) { self.item = item }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed || !item.isReadable {
                VStack(spacing: 4) {
                    Image(systemName: item.isVideo ? "video.slash" : "photo.badge.exclamationmark")
                    Text(item.isReadable ? "No preview" : "Encrypted data").font(.caption2)
                }.foregroundStyle(.secondary).padding(4)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.id) {
            guard item.isReadable else { return }
            if let hit = model.thumbnails.cached(item.id) { image = hit; return }
            image = await model.thumbnails.image(for: item.id)
            failed = image == nil && !Task.isCancelled
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    let item: RemoteItem
    @State private var confirmTrash = false

    var body: some View {
        NavigationStack {
            List {
                Section { ThumbnailCell(item: item).aspectRatio(1, contentMode: .fit).listRowInsets(EdgeInsets()) }
                Section {
                    LabeledContent("Size", value: bytes(item.size))
                    LabeledContent("Conversation", value: (item.conversation ?? "Not linked") + (item.matchedBySize ? " (by size)" : ""))
                    if let sender = item.sender { LabeledContent("From", value: sender) }
                    if let date = item.date { LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    LabeledContent("File", value: item.name)
                }
                Section {
                    if item.isLinked {
                        Button("Open Conversation in Messages", systemImage: "message") { model.openConversation(item) }
                    }
                    Button("Move to Mac's Trash…", systemImage: "trash", role: .destructive) { confirmTrash = true }
                } footer: {
                    Text("To remove it from iCloud, open the conversation in Messages, tap the name at the top, find it under Photos, and delete it there.")
                }
            }
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Move to the Mac's Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { Task { await model.trashOnMac([item.id]); dismiss() } }
            }
        }
    }
}
