import AppKit
import PolishCore
import PolishRemote
import SwiftUI

private enum Source: Hashable {
    case all, unlinked, unreadable
    case conversation(String)
}

private enum SortOrder: String, CaseIterable, Identifiable {
    case largest = "Largest", oldest = "Oldest", newest = "Newest"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var store: MediaStore
    @StateObject private var host: RemoteHost
    @State private var showShare = false
    @State private var source: Source? = .all
    @State private var kind: MediaKind?
    @State private var sort = SortOrder.largest
    @State private var selection = Set<String>()
    @State private var shown: [MediaItem] = []
    @State private var tracker = ViewportTracker()
    @State private var pendingTrash: [MediaItem] = []

    init() {
        let store = MediaStore()
        _store = StateObject(wrappedValue: store)
        _host = StateObject(wrappedValue: RemoteHost(store: store))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task { store.reload() }
        .onChange(of: store.version) { refreshShown() }
        .onChange(of: source) { refreshShown() }
        .onChange(of: kind) { refreshShown() }
        .onChange(of: sort) { refreshShown() }
        .onChange(of: store.trashedIDs) { selection.subtract(store.trashedIDs) }
        .confirmationDialog(trashTitle, isPresented: Binding(
            get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { store.trash(pendingTrash); pendingTrash = [] }
            Button("Cancel", role: .cancel) { pendingTrash = [] }
        } message: {
            let linked = pendingTrash.filter(\.isLinked).count
            Text(linked > 0
                 ? "\(linked) of these are attached to messages. Messages may show them as unavailable on this Mac. They go to the Trash, so you can put them back."
                 : "They go to the Trash, so you can put them back. Empty the Trash to free the space.")
        }
    }

    private var trashTitle: String {
        "Move \(pendingTrash.count) file\(pendingTrash.count == 1 ? "" : "s") "
            + "(\(Formatting.bytes(pendingTrash.reduce(0) { $0 + $1.size }))) to the Trash?"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $source) {
            Section("Library") {
                let readable = store.items.filter(\.isReadable)
                row("All media", count: readable.count, size: readable.reduce(0) { $0 + $1.size })
                    .tag(Source.all)
                let unlinked = readable.filter { !$0.isLinked }
                row("Not linked to a message", count: unlinked.count, size: unlinked.reduce(0) { $0 + $1.size })
                    .tag(Source.unlinked)
                let unreadable = store.items.filter { !$0.isReadable }
                row("Unplayable video data", count: unreadable.count, size: unreadable.reduce(0) { $0 + $1.size })
                    .tag(Source.unreadable)
            }
            Section("Conversations") {
                ForEach(conversations, id: \.name) { c in
                    row(c.name, count: c.count, size: c.size).tag(Source.conversation(c.name))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var conversations: [(name: String, count: Int, size: Int64)] {
        Dictionary(grouping: store.items.filter { $0.isLinked && $0.isReadable }, by: { $0.conversation ?? "" })
            .map { (name: $0.key, count: $0.value.count, size: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.size > $1.size }
    }

    private func row(_ title: String, count: Int, size: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).lineLimit(1)
            Text("\(count) files, \(Formatting.bytes(size))").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView("Reading the Messages library…")
        case .failed(let message, let needsAccess):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center)
                if needsAccess {
                    Text("Grant Full Disk Access to Apple Polish in System Settings, then reload.")
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") { MediaStore.openFullDiskAccessSettings() }
                }
                Button("Reload") { store.reload() }
            }
            .padding(40)
        case .loaded:
            grid
        }
    }

    private func refreshShown() {
        var items = store.items.filter { item in
            if let kind, item.kind != kind { return false }
            switch source ?? .all {
            case .all: return item.isReadable
            case .unlinked: return item.isReadable && !item.isLinked
            case .unreadable: return !item.isReadable
            case .conversation(let name): return item.conversation == name
            }
        }
        switch sort {
        case .largest: items.sort { $0.size > $1.size }
        case .oldest: items.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .newest: items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        shown = items
        tracker.items = items
    }

    private var grid: some View {
        let items = shown
        return VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        cell(item)
                            .onAppear { tracker.appeared(index) }
                            .onDisappear { tracker.disappeared(index) }
                    }
                }
                .padding(16)
            }
            Divider()
            footer(items)
        }
        .toolbar {
            ToolbarItem {
                Picker("Kind", selection: $kind) {
                    Text("Photos + videos").tag(MediaKind?.none)
                    Text("Videos").tag(MediaKind?.some(.video))
                    Text("Photos").tag(MediaKind?.some(.photo))
                }
            }
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            ToolbarItem {
                Button("iPhone", systemImage: host.isSharing ? "iphone.radiowaves.left.and.right" : "iphone") {
                    showShare.toggle()
                }
                .popover(isPresented: $showShare) { ShareToPhoneView(host: host) }
            }
            ToolbarItem { Button("Reload", systemImage: "arrow.clockwise") { store.reload() } }
        }
    }

    private func cell(_ item: MediaItem) -> some View {
        let selected = selection.contains(item.id)
        return VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(item: item)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Text(Formatting.bytes(item.size))
                        .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "video.fill").foregroundStyle(.white).padding(6).shadow(radius: 2)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: selected ? 3 : 0)
                }
            Text((item.conversation ?? "Not linked to a message") + (item.matchedBySize ? " (by size)" : ""))
                .font(.caption.bold()).lineLimit(1)
            Text([item.date?.formatted(date: .abbreviated, time: .omitted), item.sender]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onTapGesture { if selected { selection.remove(item.id) } else { selection.insert(item.id) } }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Open") { NSWorkspace.shared.open(item.url) }
            if item.isLinked {
                Button("Open Conversation in Messages") { store.openInMessages(item) }
            }
            Divider()
            let targets = selected ? shown.filter { selection.contains($0.id) } : [item]
            Button(targets.count > 1 ? "Move \(targets.count) Selected to Trash…" : "Move to Trash…",
                   role: .destructive) { pendingTrash = targets }
        }
    }

    private func footer(_ items: [MediaItem]) -> some View {
        let picked = items.filter { selection.contains($0.id) }
        return HStack {
            Text("\(items.count) shown, \(Formatting.bytes(items.reduce(0) { $0 + $1.size }))")
            if let message = store.statusMessage ?? store.contactsNote {
                Text(message).foregroundStyle(.secondary).lineLimit(2).help(message)
            }
            Spacer()
            Text("\(picked.count) selected, \(Formatting.bytes(picked.reduce(0) { $0 + $1.size }))")
            Button("Reveal selected in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url))
            }.disabled(picked.isEmpty)
            Button("Open in Messages") { if let one = picked.first { store.openInMessages(one) } }
                .disabled(picked.count != 1 || !(picked.first?.isLinked ?? false))
            Button("Move to Trash…", role: .destructive) { pendingTrash = picked }.disabled(picked.isEmpty)
            Button("Clear") { selection.removeAll() }.disabled(picked.isEmpty)
        }
        .font(.callout).padding(10)
    }
}
