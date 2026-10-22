import AppKit
import PolishCore
import SwiftUI

private enum Source: Hashable {
    case all, unlinked
    case conversation(String)
}

private enum SortOrder: String, CaseIterable, Identifiable {
    case largest = "Largest", oldest = "Oldest", newest = "Newest"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var store = MediaStore()
    @State private var source: Source? = .all
    @State private var kind: MediaKind?
    @State private var sort = SortOrder.largest
    @State private var selection = Set<String>()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task { store.reload() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $source) {
            Section("Library") {
                row("All media", count: store.items.count, size: store.items.reduce(0) { $0 + $1.size })
                    .tag(Source.all)
                let unlinked = store.items.filter { !$0.isLinked }
                row("Not linked to a message", count: unlinked.count, size: unlinked.reduce(0) { $0 + $1.size })
                    .tag(Source.unlinked)
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
        Dictionary(grouping: store.items.filter(\.isLinked), by: { $0.conversation ?? "" })
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

    private var visible: [MediaItem] {
        var items = store.items.filter { item in
            if let kind, item.kind != kind { return false }
            switch source ?? .all {
            case .all: return true
            case .unlinked: return !item.isLinked
            case .conversation(let name): return item.conversation == name
            }
        }
        switch sort {
        case .largest: items.sort { $0.size > $1.size }
        case .oldest: items.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .newest: items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return items
    }

    private var grid: some View {
        let items = visible
        return VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        cell(item)
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
            Text(item.conversation ?? "Not linked to a message").font(.caption.bold()).lineLimit(1)
            Text([item.date?.formatted(date: .abbreviated, time: .omitted), item.sender]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .onTapGesture { if selected { selection.remove(item.id) } else { selection.insert(item.id) } }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Open") { NSWorkspace.shared.open(item.url) }
        }
    }

    private func footer(_ items: [MediaItem]) -> some View {
        let picked = items.filter { selection.contains($0.id) }
        return HStack {
            Text("\(items.count) shown, \(Formatting.bytes(items.reduce(0) { $0 + $1.size }))")
            Spacer()
            Text("\(picked.count) selected, \(Formatting.bytes(picked.reduce(0) { $0 + $1.size }))")
            Button("Reveal selected in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.url))
            }.disabled(picked.isEmpty)
            Button("Clear") { selection.removeAll() }.disabled(picked.isEmpty)
        }
        .font(.callout).padding(10)
    }
}
