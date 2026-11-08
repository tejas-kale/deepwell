import SwiftUI
import DeepwellModel
import DeepwellIndex

struct LibraryView: View {
    @State private var model: LibraryModel
    @State private var selection: String?
    @State private var showMenu = false
    @State private var menu: MenuController?

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
                    Button {
                        if menu == nil, let i = model.index { menu = MenuController(index: i) }
                        showMenu = true
                    } label: { Label("Weekly Menu", systemImage: "calendar.badge.clock") }
                }
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
                        Divider()
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
        .sheet(isPresented: $showMenu) {
            if let menu { MenuContainerView(controller: menu) { showMenu = false } }
        }
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
