import SwiftUI
import DeepwellModel
import DeepwellIndex

struct LibraryView: View {
    @State private var model: LibraryModel
    @State private var selection: String?
    @State private var showMenu = false
    @State private var menu: MenuController?
    @State private var showTags = false

    let tagging: TaggingController

    init(folder: URL, tagging: TaggingController) {
        _model = State(initialValue: LibraryModel(folder: folder))
        self.tagging = tagging
    }

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
            .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 640)
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
        .task(id: model.index != nil) {
            // Start the Monday schedule as soon as the index is open, not only once the menu sheet was opened.
            if menu == nil, let i = model.index { menu = MenuController(index: i) }
            menu?.startSchedule()
            if UserNotificationMenuNotifier.openRequested { UserNotificationMenuNotifier.openRequested = false; showMenu = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellOpenMenu)) { _ in
            UserNotificationMenuNotifier.openRequested = false
            menu?.refresh()
            showMenu = true
        }
        .sheet(isPresented: $showMenu) {
            if let menu { MenuContainerView(controller: menu) { showMenu = false } }
        }
        .sheet(isPresented: $showTags) { TagsView(model: model) }
        .safeAreaInset(edge: .bottom) {
            if let msg = model.errorMessage { Text(msg).font(.caption).foregroundStyle(.red).padding(4) }
            else if let s = tagging.lastStatus { Text(s).font(.caption).foregroundStyle(.secondary).padding(4) }
        }
    }
}

struct ItemRow: View {
    let entry: IndexedItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            typeIcon
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.item.title.isEmpty ? "Untitled" : entry.item.title)
                    .fontWeight(entry.item.status == .unread ? .semibold : .regular)
                    .foregroundStyle(entry.item.status == .done ? .secondary : .primary)
                    .lineLimit(2)
                if !entry.item.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(entry.item.tags, id: \.self) { t in
                            let isNew = entry.newTags.contains(t)
                            Text(isNew ? "\(t) • new" : t)
                                .font(.caption2).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(isNew ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.item.capturedAt, format: .dateTime.day().month(.abbreviated)).fixedSize()
                    if entry.item.status == .reading { ProgressView(value: entry.item.progress).frame(width: 40) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let snippet = entry.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// The type icon carries the status: a blue dot = unread, a half-filled ring = in progress, a check = done.
    private var typeIcon: some View {
        Image(systemName: icon)
            .font(.title3).foregroundStyle(.secondary).frame(width: 26, height: 26)
            .overlay(alignment: .topTrailing) {
                switch entry.item.status {
                case .unread: Circle().fill(.blue).frame(width: 9, height: 9).offset(x: 3, y: -2)
                case .reading: Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)).foregroundStyle(.orange).offset(x: 4, y: -3)
                case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green).offset(x: 4, y: -3)
                }
            }
            .help(entry.item.status.rawValue.capitalized)
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

/// Left-to-right layout that wraps onto new lines, so tags are never truncated to "age…".
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(subviews, width: bounds.width)
        for (i, p) in r.origins.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowH = max(rowH, size.height); maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowH))
    }
}
