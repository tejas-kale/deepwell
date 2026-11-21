import SwiftUI
import DeepwellUI
import DeepwellIndex
import DeepwellModel

/// iPhone (compact width): a tab per section, each a navigation stack ending in the reader.
/// iPad (regular width): NavigationSplitView, sidebar → queue → reader, close to the Mac layout.
struct MobileRootView: View {
    @Environment(MobileAppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch app.phase {
            case .opening:
                ProgressView("Opening your library…")
            case .signedOut:
                ContentUnavailableView {
                    Label("iCloud is off", systemImage: "icloud.slash")
                } description: {
                    Text("Deepwell reads your library from iCloud Drive › Deepwell. Sign in to iCloud in Settings and make sure iCloud Drive is on for Deepwell. Nothing is kept on this device without it.")
                } actions: {
                    Button("Try Again") { app.open() }
                }
            case .ready:
                if let library = app.library {
                    if sizeClass == .compact { PhoneRoot(library: library) } else { PadRoot(library: library) }
                }
            }
        }
        .ayuTheme()
        .onChange(of: scenePhase) {
            if scenePhase == .active { app.becameActive() }
            if scenePhase == .background { app.enteredBackground() }
        }
        .overlay(alignment: .bottom) {
            if let msg = app.library?.errorMessage {
                Text(msg).font(.caption).padding(8).background(.thinMaterial, in: Capsule()).padding()
            }
        }
    }
}

/// The item a tapped reading nudge opens (docs/menu.md, Nudges): its id when it can be read here, nil (show Current
/// Focus only) when it is not on this device yet or is already done.
@MainActor
private func readableNudgeItem(_ id: String, in library: FocusLibrary) -> String? {
    guard let entry = library.entry(id: id), entry.item.status != .done else { return nil }
    return id
}

private struct PhoneRoot: View {
    let library: FocusLibrary
    @State private var tab = MobileSection.focus
    @State private var focusPath: [String] = []

    var body: some View {
        TabView(selection: $tab) {
            Tab(MobileSection.focus.title, systemImage: MobileSection.focus.symbol, value: .focus) {
                NavigationStack(path: $focusPath) { FocusQueueList(library: library).readerDestination(library) }
            }
            Tab(MobileSection.library.title, systemImage: MobileSection.library.symbol, value: .library) {
                NavigationStack { LibraryScreen(library: library).readerDestination(library) }
            }
            Tab(MobileSection.settings.title, systemImage: MobileSection.settings.symbol, value: .settings) {
                NavigationStack { SettingsScreen() }
            }
        }
        .onNudgeTapped(openNudgeItem)
    }

    /// The item in the reader on the Current Focus tab, or that tab's queue alone.
    private func openNudgeItem(_ id: String) {
        tab = .focus
        focusPath = readableNudgeItem(id, in: library).map { [$0] } ?? []
    }
}

private struct PadRoot: View {
    let library: FocusLibrary
    @State private var section: MobileSection? = .focus
    @State private var itemID: String?
    @State private var visibility = NavigationSplitViewVisibility.all
    /// Set when a tapped nudge switches the section, so that switch keeps the nudge's item selected.
    @State private var keepSelection = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(MobileSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol)
            }
            .navigationTitle("Deepwell")
        } content: {
            switch section ?? .focus {
            case .focus: FocusQueueList(library: library, selection: $itemID)
            case .library: LibraryScreen(library: library, selection: $itemID)
            case .settings: SettingsScreen()
            }
        } detail: {
            if section == .settings {
                ContentUnavailableView("Settings", systemImage: "gearshape", description: Text("Keys sync with your Mac through iCloud Keychain."))
            } else if let itemID, let entry = library.entry(id: itemID) {
                reader(library, entry).id(itemID)
            } else {
                ContentUnavailableView("Pick something to read", systemImage: "text.book.closed")
            }
        }
        .onChange(of: section) { if keepSelection { keepSelection = false } else { itemID = nil } }
        .onNudgeTapped(openNudgeItem)
    }

    /// Current Focus with the item in the reader column, or Current Focus alone.
    private func openNudgeItem(_ id: String) {
        if section != .focus { keepSelection = true; section = .focus }
        itemID = readableNudgeItem(id, in: library)
    }
}

private extension View {
    /// Calls `open` with the item id of a tapped reading nudge: one that arrives while this view is shown, or one that
    /// cold-launched the app before any view was listening. Clears that cold-launch tap.
    func onNudgeTapped(_ open: @escaping (String) -> Void) -> some View {
        onAppear {
            guard let id = UserNotificationNudgeScheduler.pendingItemID else { return }
            UserNotificationNudgeScheduler.pendingItemID = nil
            open(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellOpenNudgeItem)) { n in
            guard let id = n.object as? String else { return }
            UserNotificationNudgeScheduler.pendingItemID = nil
            open(id)
        }
    }

    func readerDestination(_ library: FocusLibrary) -> some View {
        navigationDestination(for: String.self) { id in
            if let entry = library.entry(id: id) {
                reader(library, entry)
            } else {
                ContentUnavailableView("Not in the library", systemImage: "questionmark.folder")
            }
        }
    }
}

@MainActor
private func reader(_ library: FocusLibrary, _ entry: IndexedItem) -> some View {
    MobileReaderView(entry: entry, url: library.fileURL(for: entry), libraryFolder: library.folder,
                     onChanged: { library.itemChanged() })
}
