import SwiftUI
import DeepwellUI
import DeepwellModel
import DeepwellIndex

/// Ticket 19: every capture, with type / status / tag filters and full-text search over this device's index, opening
/// the same reader as the other tabs. The Tags button opens the shared curation screen (`TagsView`): rename, merge,
/// delete, accept new, each logged in `.deepwell/tag-ops.jsonl` so the other device can't bring an old tag back.
struct LibraryScreen: View {
    @Bindable var library: FocusLibrary
    /// iPad: the selected row drives the reader column. iPhone: nil, rows push with NavigationLink.
    var selection: Binding<String?>?
    @State private var showingTags = false

    private var searching: Bool { !library.searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var filtered: Bool { library.filter != ItemFilter() }

    var body: some View {
        list
            .ayuSurface(Ayu.panel)
            .overlay {
                if library.libraryItems.isEmpty {
                    if searching || filtered {
                        ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                               description: Text(filtered ? "Try clearing the filters." : ""))
                    } else if library.isIndexing {
                        ProgressView("Loading the library…")
                    } else {
                        ContentUnavailableView("No items yet", systemImage: "tray",
                                               description: Text("Share a page or a link to Deepwell to save it."))
                    }
                }
            }
            .searchable(text: $library.searchText, prompt: "Search all captures")
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    filterMenu
                    Button { showingTags = true } label: { Label("Tags", systemImage: "tag") }
                }
            }
            .sheet(isPresented: $showingTags) { TagsView(model: library) }
            .refreshable { library.refresh() }
    }

    @ViewBuilder private var list: some View {
        if let selection {
            List(selection: selection) {
                filterSummary
                ForEach(library.libraryItems, id: \.item.id) { e in row(e).tag(e.item.id) }
            }
        } else {
            List {
                filterSummary
                ForEach(library.libraryItems, id: \.item.id) { e in NavigationLink(value: e.item.id) { row(e) } }
            }
        }
    }

    private func row(_ e: IndexedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ItemRow(entry: e, typeSymbol: e.item.type.symbol)
            if e.item.needsTranscript { TranscriptPendingLabel().padding(.leading, 36) }
        }
    }

    /// What's filtered, with a one-tap reset (the menu shows the same choices).
    @ViewBuilder private var filterSummary: some View {
        if filtered {
            Section {
                HStack {
                    Text(filterDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Clear") { library.filter = ItemFilter() }.font(.caption)
                }
            }
        }
    }

    private var filterDescription: String {
        var parts: [String] = []
        if let t = library.filter.type { parts.append(t.libraryTitle) }
        if let s = library.filter.status { parts.append(s.libraryTitle) }
        if let tag = library.filter.tag { parts.append("#\(tag)") }
        if library.filter.hasNewTags { parts.append("new tags") }
        return "Showing " + parts.joined(separator: " · ")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $library.filter.type) {
                Text("All Types").tag(ItemType?.none)
                ForEach(ItemType.allCases, id: \.self) { t in
                    Label(t.libraryTitle, systemImage: t.symbol).tag(ItemType?.some(t))
                }
            }
            Picker("Status", selection: $library.filter.status) {
                Text("Any Status").tag(ItemStatus?.none)
                ForEach(ItemStatus.allCases, id: \.self) { s in
                    Label(s.libraryTitle, systemImage: s.symbol).tag(ItemStatus?.some(s))
                }
            }
            if !library.tagSummaries.isEmpty {
                Picker("Tag", selection: $library.filter.tag) {
                    Text("Any Tag").tag(String?.none)
                    ForEach(library.tagSummaries, id: \.name) { t in
                        Text("\(t.name) (\(t.itemCount))").tag(String?.some(t.name))
                    }
                }
                .pickerStyle(.menu)
            }
            Toggle("New Tags Only", isOn: $library.filter.hasNewTags)
            if filtered {
                Divider()
                Button("Clear Filters", role: .destructive) { library.filter = ItemFilter() }
            }
        } label: {
            Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

private extension ItemType {
    var libraryTitle: String {
        switch self {
        case .article: "Articles"
        case .youtube: "Videos"
        case .podcast: "Podcasts"
        case .magazineArticle: "Magazine articles"
        }
    }
}

private extension ItemStatus {
    var libraryTitle: String {
        switch self { case .unread: "Unread"; case .reading: "Reading"; case .done: "Done" }
    }
}
