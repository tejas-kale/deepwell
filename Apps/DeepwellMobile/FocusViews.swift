import SwiftUI
import DeepwellUI
import DeepwellModel
import DeepwellIndex
import DeepwellMenu

/// What the iPad sidebar (and the iPhone tab bar) offers. Library (browse, filter, search, tags) is ticket 19.
enum MobileSection: String, Hashable, CaseIterable, Identifiable {
    case focus, reading, library, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .focus: "Current Focus"; case .reading: "Reading"; case .library: "Library"; case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .focus: "scope"; case .reading: "book"; case .library: "books.vertical"; case .settings: "gearshape"
        }
    }
}

/// This week's picked bundle, in pick order, with each item's length and reason and the time-weighted progress.
/// Rows carry their item id as the list's selection/navigation value.
struct FocusQueueList: View {
    let library: FocusLibrary
    /// iPad: the selected row drives the reader column. iPhone: nil, rows push with NavigationLink.
    var selection: Binding<String?>?

    var body: some View {
        Group {
            if let focus = library.focus {
                if let queue = focus.queue, let progress = focus.progress {
                    list(queue: queue, progress: progress)
                } else {
                    ContentUnavailableView {
                        Label("Build a menu on your Mac", systemImage: "menucard")
                    } description: {
                        Text("Open Deepwell on your Mac, build this week's menu and pick a bundle. It appears here.")
                    }
                }
            } else {
                ProgressView("Reading this week's pick…")
            }
        }
        .navigationTitle("Current Focus")
        .refreshable { library.refresh() }
    }

    @ViewBuilder private func list(queue: WeekQueue, progress: QueueProgress) -> some View {
        let rows = Array(progress.rows.enumerated())
        if let selection {
            List(selection: selection) {
                header(queue: queue, progress: progress)
                Section { ForEach(rows, id: \.offset) { n, row in rowView(n, row).tag(row.entry.itemID) } }
            }
            .ayuSurface(Ayu.panel)
        } else {
            List {
                header(queue: queue, progress: progress)
                Section {
                    ForEach(rows, id: \.offset) { n, row in
                        if library.entry(id: row.entry.itemID) != nil {
                            NavigationLink(value: row.entry.itemID) { rowView(n, row) }
                        } else {
                            rowView(n, row)
                        }
                    }
                }
            }
            .ayuSurface(Ayu.panel)
        }
    }

    private func header(queue: WeekQueue, progress: QueueProgress) -> some View {
        let total = progress.rows.reduce(0) { $0 + $1.entry.minutes }
        let left = progress.rows.reduce(0.0) { $0 + Double($1.entry.minutes) * (1 - $1.progress) }
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(queue.topic).font(.title3.weight(.semibold))
                ProgressView(value: progress.fraction).tint(Ayu.accent)
                Text("\(progress.doneCount) of \(progress.rows.count) done · \(Int(progress.fraction * 100))% · \(Self.minutes(Int(left.rounded()))) left of \(Self.minutes(total))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func rowView(_ n: Int, _ row: QueueProgress.Row) -> some View {
        let entry = library.entry(id: row.entry.itemID)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.status?.symbol ?? "questionmark.circle")
                .foregroundStyle(row.status == .done ? Ayu.green : Ayu.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.entry.title).font(.body.weight(.medium))
                    .strikethrough(row.status == .done, color: .secondary)
                HStack(spacing: 6) {
                    if let type = entry?.item.type { Image(systemName: type.symbol) }
                    Text(Self.minutes(row.entry.minutes))
                    if row.status == .reading { Text("· \(Int(row.progress * 100))%") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if entry?.item.needsTranscript == true { TranscriptPendingLabel() }
                if !row.entry.reason.isEmpty {
                    Text(row.entry.reason).font(.callout).foregroundStyle(.secondary)
                }
                if row.status == nil {
                    Text(library.isIndexing ? "Loading from iCloud…" : "No longer in the library")
                        .font(.caption).foregroundStyle(Ayu.red)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(n + 1). \(row.entry.title)")
    }

    static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
    }
}

/// What's left to read: magazine issues still splitting on the Mac, then items in progress (status `reading`), then
/// unread items, each newest capture first. Done items aren't listed (the Library tab has everything); empty
/// sections are left out.
struct ReadingList: View {
    let library: FocusLibrary
    var selection: Binding<String?>?

    var body: some View {
        Group {
            if library.inProgress.isEmpty && library.unread.isEmpty && library.pendingIssues.isEmpty {
                ContentUnavailableView("Nothing to read", systemImage: "book",
                                       description: Text("Unread items and items you've started show up here."))
            } else if let selection {
                List(selection: selection) {
                    pendingSection
                    itemSection("Reading", library.inProgress) { row($0).tag($0.item.id) }
                    itemSection("Unread", library.unread) { row($0).tag($0.item.id) }
                }
                .ayuSurface(Ayu.panel)
            } else {
                List {
                    pendingSection
                    itemSection("Reading", library.inProgress) { e in NavigationLink(value: e.item.id) { row(e) } }
                    itemSection("Unread", library.unread) { e in NavigationLink(value: e.item.id) { row(e) } }
                }
                .ayuSurface(Ayu.panel)
            }
        }
        .navigationTitle("Reading")
        .refreshable { library.refresh() }
    }

    /// Ticket 20: magazine issues shared from this device (or another) that the Mac hasn't split yet.
    @ViewBuilder private var pendingSection: some View {
        if !library.pendingIssues.isEmpty {
            Section("Magazine issues") {
                ForEach(library.pendingIssues, id: \.issueID) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).font(.body.weight(.medium))
                        Label("Splitting on Mac", systemImage: "books.vertical")
                            .font(.caption).foregroundStyle(Ayu.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemSection<Row: View>(_ title: String, _ items: [IndexedItem],
                                        @ViewBuilder row: @escaping (IndexedItem) -> Row) -> some View {
        if !items.isEmpty {
            Section(title) { ForEach(items, id: \.item.id) { row($0) } }
        }
    }

    /// Unread rows show no percentage.
    private func row(_ e: IndexedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.item.title).font(.body.weight(.medium))
            HStack(spacing: 6) {
                Image(systemName: e.item.type.symbol)
                if e.item.status == .reading { Text("\(Int(e.item.progress * 100))%") }
                if let a = e.item.author { Text("· \(a)").lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if e.item.needsTranscript { TranscriptPendingLabel() }
        }
    }
}

/// Ticket 18: a video or podcast saved without a published transcript; the Mac transcribes it.
struct TranscriptPendingLabel: View {
    var body: some View {
        Label(TranscriptPending.title, systemImage: "waveform.badge.ellipsis")
            .font(.caption).foregroundStyle(Ayu.accent)
    }
}
