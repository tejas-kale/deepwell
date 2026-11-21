import AppKit
import SwiftUI
import DeepwellUI
import DeepwellModel
import DeepwellIndex
import DeepwellLibrary
import DeepwellMenu

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
    @State private var nudge: NudgeController?
    @State private var browsingMenu = false
    @State private var showTags = false
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var pane: Pane?
    @State private var scroller = ReaderScroller()
    /// Set when the focus was already sent once: asks before sending again.
    @State private var resendDate: Date?

    let tagging: TaggingController
    let kindle: KindleController

    init(location: LibraryLocation, tagging: TaggingController, kindle: KindleController,
         onLibraryChange: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: LibraryModel(location: location, onLibraryChange: onLibraryChange))
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
            if menu == nil, let i = model.index { menu = MenuController(index: i, library: model.folder) }
            // Reading nudge (docs/menu.md, Nudges): the launch check runs once the queue and the items are known.
            if nudge == nil, let menu {
                nudge = NudgeController { [model] in
                    menu.refresh()
                    return CurrentFocus(queue: menu.state.queue, items: model.allItems.map(\.item))
                }
            }
            if let id = UserNotificationNudgeScheduler.pendingItemID { openNudgeItem(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellOpenNudgeItem)) { n in
            if let id = n.object as? String { openNudgeItem(id) }
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

    /// A clicked reading nudge: the item in the reader, beside Current Focus. Current Focus alone if the item is not
    /// (yet) on this Mac or is already done.
    private func openNudgeItem(_ id: String) {
        UserNotificationNudgeScheduler.pendingItemID = nil
        menu?.refresh()
        model.searchText = ""
        model.section = .focus
        browsingMenu = false
        if let entry = model.entry(id: id), entry.item.status != .done { selection = entry.relativePath; pane = .reader }
        else { selection = nil }
        NSApp.activate(ignoringOtherApps: true)
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

    /// The item a Delete was asked for (right click, or the Delete key on the selected row), until confirmed.
    @State private var deleting: IndexedItem?

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List(model.items, id: \.relativePath, selection: $selection) { entry in
            ItemRow(entry: entry, typeSymbol: entry.item.type.symbol)
                .contextMenu { Button("Delete…", role: .destructive) { deleting = entry } }
                .tag(entry.relativePath)
        }
        .onDeleteCommand { deleting = selection.flatMap { model.entry(path: $0) } }
        .confirmationDialog("Delete \"\(deleting?.item.title ?? "")\"?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { entry in
            Button("Delete", role: .destructive) {
                if selection == entry.relativePath { selection = nil }
                model.delete(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.item.type == .magazineArticle
                 ? "It moves to the Trash and leaves the library on all your devices. Deleting an issue's last article also removes the issue's original file."
                 : "It moves to the Trash and leaves the library on all your devices.")
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
