import PolishRemote
import SwiftUI

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

struct LocalLibraryView: View {
    @StateObject private var model = LocalLibraryModel()
    @State private var filter = LocalFilter.all
    @State private var sort = LocalSort.largest
    @State private var minMB = 0
    @State private var shown: [LocalAssetInfo] = []
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false
    @State private var detail: LocalAssetInfo?

    var body: some View {
        NavigationStack {
            Group {
                switch model.access {
                case .unknown: ProgressView("Asking for Photos access…")
                case .denied: denied
                case .limited, .authorized: grid
                }
            }
            .navigationTitle("This iPhone")
        }
        .task { await model.start() }
        .onChange(of: model.version) { refresh() }
        .onChange(of: filter) { refresh() }
        .onChange(of: sort) { refresh() }
        .onChange(of: minMB) { refresh() }
        .alert("Apple Polish", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
    }

    private func refresh() {
        shown = LocalLibraryQuery.apply(model.infos, filter: filter, sort: sort, minBytes: Int64(minMB) * 1_000_000)
        selection.formIntersection(Set(shown.map(\.id)))
    }

    private var denied: some View {
        ContentUnavailableView {
            Label("Photos access is off", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Allow access to Photos in Settings to find large photos and videos on this iPhone.")
        } actions: {
            Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
        }
    }

    private var grid: some View {
        let items = shown
        return ScrollView {
            if model.access == .limited {
                Text("Limited access: only the photos you shared with this app are listed.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    cell(item)
                        .onAppear { model.prefetch(items, around: index) }
                        .onTapGesture { tap(item) }
                }
            }
            .padding(6)
        }
        .safeAreaInset(edge: .top) { status(items) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) { ForEach(LocalFilter.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("Sort", selection: $sort) { ForEach(LocalSort.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("At least", selection: $minMB) {
                        Text("Any size").tag(0); Text("5 MB").tag(5); Text("25 MB").tag(25); Text("100 MB").tag(100)
                    }
                    Button(selecting ? "Done selecting" : "Select") { selecting.toggle(); if !selecting { selection.removeAll() } }
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                    Button("Re-measure everything", systemImage: "ruler") { Task { await model.reload(forceMeasure: true) } }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if selecting {
                    Text("\(selection.count) selected, \(bytes(LocalLibraryQuery.totalBytes(items.filter { selection.contains($0.id) })))")
                        .font(.footnote)
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete \(selection.count) item\(selection.count == 1 ? "" : "s") from this iPhone?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let ids = Array(selection)
                Task { await model.delete(ids); selection.removeAll(); selecting = false }
            }
        } message: {
            Text("iOS will ask you to confirm. They go to Recently Deleted for 30 days; if iCloud Photos is on, the deletion syncs to your other devices and frees iCloud space once Recently Deleted is emptied.")
        }
        .sheet(item: $detail) { item in LocalDetailView(item: item) }
        .onDisappear { model.stopPrefetching() }
        .onAppear { refresh() }
    }

    private func status(_ items: [LocalAssetInfo]) -> some View {
        HStack {
            Text("\(items.count) shown, \(bytes(LocalLibraryQuery.totalBytes(items)))")
            Spacer()
            if model.isMeasuring {
                Text("Measuring sizes \(model.measured)/\(model.infos.count)")
            }
        }
        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 4).background(.bar)
    }

    private func tap(_ item: LocalAssetInfo) {
        if selecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            detail = item
        }
    }

    private func cell(_ item: LocalAssetInfo) -> some View {
        LocalThumbnail(model: model, id: item.id)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Text(item.size.map(bytes) ?? "…").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Label(duration(item.duration), systemImage: "video.fill").font(.caption2).labelStyle(.titleAndIcon)
                        .foregroundStyle(.white).padding(5).shadow(radius: 2)
                }
            }
            .overlay(alignment: .topLeading) {
                if selecting {
                    Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white, selection.contains(item.id) ? .blue : .gray).padding(5)
                }
            }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct LocalThumbnail: View {
    let model: LocalLibraryModel
    let id: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)  // original lives in iCloud, not on this iPhone
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: id) {
            image = await model.thumbnail(for: id)
            failed = image == nil && !Task.isCancelled
        }
    }
}

struct LocalDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: LocalAssetInfo

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Type", value: item.isVideo ? "Video" : item.isLivePhoto ? "Live Photo" : item.isScreenshot ? "Screenshot" : "Photo")
                LabeledContent("Size", value: item.size.map(bytes) ?? "Measuring…")
                if item.isVideo { LabeledContent("Length", value: String(format: "%d:%02d", Int(item.duration) / 60, Int(item.duration) % 60)) }
                if let date = item.date { LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .shortened)) }
            }
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
