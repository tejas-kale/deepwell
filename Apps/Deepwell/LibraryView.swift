import SwiftUI
import DeepwellModel
import DeepwellIndex

struct LibraryView: View {
    @State private var model: LibraryModel
    @State private var selection: String?
    @State private var showTags = false

    init(folder: URL) { _model = State(initialValue: LibraryModel(folder: folder)) }

    var body: some View {
        NavigationSplitView {
            List(model.items, id: \.relativePath, selection: $selection) { entry in
                ItemRow(entry: entry).tag(entry.relativePath)
            }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView(model.searchText.isEmpty ? "No items yet" : "No matches",
                                           systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass",
                                           description: Text(model.searchText.isEmpty ? "Press the Deepwell button in Safari to save a page." : ""))
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .searchable(text: $model.searchText, prompt: "Search title and text")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Type", selection: $model.typeFilter) {
                            Text("All types").tag(ItemType?.none)
                            ForEach(ItemType.allCases, id: \.self) { Text($0.rawValue).tag(ItemType?.some($0)) }
                        }
                        Picker("Status", selection: $model.statusFilter) {
                            Text("Any status").tag(ItemStatus?.none)
                            ForEach(ItemStatus.allCases, id: \.self) { Text($0.rawValue).tag(ItemStatus?.some($0)) }
                        }
                        Picker("Tag", selection: $model.tagFilter) {
                            Text("All tags").tag(String?.none)
                            ForEach(model.tagSummaries, id: \.name) { Text("\($0.name) (\($0.itemCount))").tag(String?.some($0.name)) }
                        }
                        Divider()
                        Button("Manage Tags…") { showTags = true }
                        Button("Rebuild Index") { model.rebuildIndex() }
                    } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                }
            }
        } detail: {
            if let path = selection, let entry = model.items.first(where: { $0.relativePath == path }) ?? nil {
                ReaderView(entry: entry, url: model.fileURL(for: entry)) { model.scheduleSync() }
                    .id(entry.relativePath)
            } else {
                Text("Select an item").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showTags) { TagsView(model: model) }
        .safeAreaInset(edge: .bottom) {
            if let msg = model.errorMessage { Text(msg).font(.caption).foregroundStyle(.red).padding(4) }
        }
    }
}

struct ItemRow: View {
    let entry: IndexedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(entry.item.title.isEmpty ? "Untitled" : entry.item.title)
                    .fontWeight(entry.item.status == .unread ? .semibold : .regular)
                    .lineLimit(2)
            }
            if !entry.item.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(entry.item.tags, id: \.self) { t in
                        Text(entry.newTags.contains(t) ? "\(t) • new" : t)
                            .font(.caption2).padding(.horizontal, 5)
                            .background(entry.newTags.contains(t) ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            HStack(spacing: 6) {
                Text(entry.item.type.rawValue)
                Text(entry.item.capturedAt, style: .date)
                Text(entry.item.status.rawValue)
                if entry.item.status == .reading { ProgressView(value: entry.item.progress).frame(width: 40) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let snippet = entry.snippet {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.item.type {
        case .article: "doc.text"
        case .youtube: "play.rectangle"
        case .podcast: "waveform"
        case .magazineArticle: "newspaper"
        }
    }
}
