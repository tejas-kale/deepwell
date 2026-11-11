import SwiftUI
import DeepwellModel
import DeepwellIndex

extension Notification.Name {
    /// Library > Weekly Menu: show the menu in the Current Focus column.
    static let deepwellOpenMenu = Notification.Name("deepwell.openMenu")
    /// Library > Build New Focus: rebuild the menu and show it, ready to pick the new focus.
    static let deepwellBuildFocus = Notification.Name("deepwell.buildFocus")
    static let deepwellManageTags = Notification.Name("deepwell.manageTags")
    static let deepwellRebuildIndex = Notification.Name("deepwell.rebuildIndex")
    /// Library > Send Focus to Kindle.
    static let deepwellSendToKindle = Notification.Name("deepwell.sendToKindle")
}

/// Three columns: sidebar (Current Focus, All Captures, filters) | list | reader.
struct LibraryView: View {
    @State private var model: LibraryModel
    @State private var selection: String?
    @State private var menu: MenuController?
    @State private var browsingMenu = false
    @State private var showTags = false
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var pane: Pane?
    @State private var scroller = ReaderScroller()
    /// Set when the focus was already sent once: asks before sending again.
    @State private var resendDate: Date?

    let tagging: TaggingController
    let kindle: KindleController

    init(folder: URL, tagging: TaggingController, kindle: KindleController) {
        _model = State(initialValue: LibraryModel(folder: folder))
        self.tagging = tagging
        self.kindle = kindle
    }

    /// Searching from Current Focus searches all captures.
    private var showsFocus: Bool { model.section == .focus && model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model, focusRemaining: menu?.progress.map { p in p.rows.filter { $0.status != nil && $0.status != .done }.count } ?? 0,
                        manageTags: { showTags = true }, pane: $pane)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            Group {
                if showsFocus, let menu {
                    CurrentFocusView(controller: menu, library: model, selection: $selection, browsingMenu: $browsingMenu, pane: $pane)
                } else {
                    ItemList(model: model, selection: $selection, pane: $pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 600)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search all captures")
        } detail: {
            Group {
                if let path = selection, let entry = model.entry(path: path) {
                    ReaderView(entry: entry, url: model.fileURL(for: entry), libraryFolder: model.folder) { model.scheduleSync() }
                        .id(entry.relativePath)
                } else {
                    Text("Select an item").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ayu.background)
            .background(ReaderScrollProbe(scroller: scroller))
            .focusable()
            .focusEffectDisabled()
            .focused($pane, equals: .reader)
            .readerScrollKeys(scroller)
        }
        .ayuTheme()
        .task(id: model.index != nil) {
            if menu == nil, let i = model.index { menu = MenuController(index: i) }
        }
        .onChange(of: model.revision) { menu?.refresh() }   // the week's progress follows item status
        .onReceive(NotificationCenter.default.publisher(for: .deepwellOpenMenu)) { _ in openMenu() }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellBuildFocus)) { _ in
            openMenu()
            menu?.rebuild()   // no-op while a build is already running
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellManageTags)) { _ in showTags = true }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellRebuildIndex)) { _ in model.rebuildIndex() }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellFocusPane)) { n in
            guard let p = (n.object as? String).flatMap(Pane.init(rawValue:)) else { return }
            if p == .sidebar { columns = .all }
            pane = p
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellSendToKindle)) { _ in sendToKindle() }
        .alert("Send this focus to Kindle again?", isPresented: Binding(get: { resendDate != nil }, set: { if !$0 { resendDate = nil } })) {
            Button("Send Again") { resendDate = nil; sendToKindle(force: true) }
            Button("Cancel", role: .cancel) { resendDate = nil }
        } message: {
            Text("It was already sent on \(resendDate?.formatted(date: .abbreviated, time: .shortened) ?? "").")
        }
        .sheet(isPresented: $showTags) { TagsView(model: model).ayuTheme() }
        .safeAreaInset(edge: .bottom) {
            if let msg = model.errorMessage { Text(msg).font(.caption).foregroundStyle(Ayu.red).padding(4) }
            else if let s = kindle.status {
                HStack(spacing: 6) {
                    if kindle.isSending { ProgressView().controlSize(.mini) }
                    Text(s).font(.caption).foregroundStyle(kindle.statusIsError ? AnyShapeStyle(Ayu.red) : AnyShapeStyle(.secondary))
                }
                .padding(4)
            }
            else if let s = tagging.lastStatus { Text(s).font(.caption).foregroundStyle(.secondary).padding(4) }
        }
    }

    private func sendToKindle(force: Bool = false) {
        guard let q = menu?.state.queue else {
            kindle.notify("Pick a focus bundle first (Library > Weekly Menu).")
            return
        }
        if !force, let sent = kindle.lastSent(q) { resendDate = sent; return }
        kindle.send(q, library: model)
    }

    private func openMenu() {
        menu?.refresh()
        model.searchText = ""
        model.section = .focus
        browsingMenu = true
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    let model: LibraryModel
    let focusRemaining: Int
    let manageTags: () -> Void
    var pane: FocusState<Pane?>.Binding
    /// Folded until you open it; then it stays the way you left it.
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = false

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Section {
                Label("Current Focus", systemImage: "scope")
                    .badge(focusRemaining)
                    .tag(LibrarySection.focus)
                Label("All Captures", systemImage: "tray.full")
                    .badge(model.allItems.count)
                    .tag(LibrarySection.all)
            }
            Section("Type") {
                ForEach(ItemType.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.symbol).badge(model.count(t)).tag(LibrarySection.type(t))
                }
            }
            Section("Status") {
                ForEach(ItemStatus.allCases, id: \.self) { s in
                    Label(s.rawValue.capitalized, systemImage: s.symbol).badge(model.count(s)).tag(LibrarySection.status(s))
                }
            }
            Section(isExpanded: $tagsExpanded) {
                ForEach(model.tagSummaries, id: \.name) { t in
                    Label(t.name, systemImage: t.newCount > 0 ? "tag.fill" : "tag")
                        .badge(t.itemCount)
                        .tag(LibrarySection.tag(t.name))
                        .contextMenu { Button("Manage Tags…", action: manageTags) }
                }
            } header: {
                HStack {
                    Text("Tags")
                    Spacer()
                    Button(action: manageTags) { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help("Manage Tags")
                }
            }
        }
        .listStyle(.sidebar)
        .focused(pane, equals: .sidebar)
        .ayuSurface(Ayu.panel)
        .onChange(of: model.section) { if case .tag = model.section { tagsExpanded = true } }
    }
}

extension ItemType {
    var displayName: String {
        switch self {
        case .article: "Articles"
        case .youtube: "Videos"
        case .podcast: "Podcasts"
        case .magazineArticle: "Magazines"
        }
    }

    var symbol: String {
        switch self {
        case .article: "doc.text"
        case .youtube: "play.rectangle"
        case .podcast: "waveform"
        case .magazineArticle: "newspaper"
        }
    }
}

extension ItemStatus {
    var symbol: String {
        switch self {
        case .unread: "circle"
        case .reading: "circle.lefthalf.filled"
        case .done: "checkmark.circle"
        }
    }
}

// MARK: - Item list

private struct ItemList: View {
    let model: LibraryModel
    @Binding var selection: String?
    var pane: FocusState<Pane?>.Binding

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List(model.items, id: \.relativePath, selection: $selection) { entry in
            ItemRow(entry: entry).tag(entry.relativePath)
        }
        .focused(pane, equals: .list)
        .ayuSurface(Ayu.panel)
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView(searching ? "No matches" : "No items yet",
                                       systemImage: searching ? "magnifyingglass" : "tray",
                                       description: Text(searching ? "" : "Press the Deepwell button in Safari to save a page."))
            }
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
                    .foregroundStyle(entry.item.status == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ayu.text))
                    .lineLimit(2)
                if let line = entry.snippet ?? entry.item.summary.flatMap({ $0.isEmpty ? nil : $0 }) {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !entry.item.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(entry.item.tags, id: \.self) { t in
                            let isNew = entry.newTags.contains(t)
                            Text(isNew ? "\(t) • new" : t)
                                .font(.caption2).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(isNew ? Ayu.accent.opacity(0.3) : Ayu.chip, in: Capsule())
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.item.capturedAt, format: .dateTime.day().month(.abbreviated)).fixedSize()
                    if entry.item.status == .reading { ProgressView(value: entry.item.progress).frame(width: 40) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// The type icon carries the status: a blue dot = unread, a half-filled ring = in progress, a check = done.
    private var typeIcon: some View {
        Image(systemName: entry.item.type.symbol)
            .font(.title3).foregroundStyle(.secondary).frame(width: 26, height: 26)
            .overlay(alignment: .topTrailing) { StatusBadge(status: entry.item.status) }
            .help(entry.item.status.rawValue.capitalized)
    }
}

struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .unread: Circle().fill(Ayu.blue).frame(width: 9, height: 9).offset(x: 3, y: -2)
        case .reading: Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)).foregroundStyle(Ayu.orange).offset(x: 4, y: -3)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Ayu.green).offset(x: 4, y: -3)
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
