import SwiftUI
import DeepwellUI
import DeepwellModel
import DeepwellIndex
import DeepwellMenu
import DeepwellNarration

/// What the iPad sidebar (and the iPhone tab bar) offers. Library (browse, filter, search, tags) is ticket 19.
enum MobileSection: String, Hashable, CaseIterable, Identifiable {
    case focus, library, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .focus: "Current Focus"; case .library: "Library"; case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .focus: "scope"; case .library: "books.vertical"; case .settings: "gearshape"
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
                    if let pin = library.pinStates[row.entry.itemID] { PinBadge(state: pin) }
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

/// Ticket 20: magazine issues shared from this device (or another) that the Mac hasn't split yet. Shown at the top of
/// the Library (the Reading tab that used to hold it was removed).
struct PendingIssuesSection: View {
    let library: FocusLibrary

    var body: some View {
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
}

/// Ticket 18: a video or podcast saved without a published transcript; the Mac transcribes it.
struct TranscriptPendingLabel: View {
    var body: some View {
        Label(TranscriptPending.title, systemImage: "waveform.badge.ellipsis")
            .font(.caption).foregroundStyle(Ayu.accent)
    }
}

/// Ticket 17: whether a Current Focus item is downloaded for offline reading and listening.
struct PinBadge: View {
    let state: OfflinePins.State

    var body: some View {
        switch state {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Ayu.green)
                .accessibilityLabel("Downloaded")
        case .downloading:
            Image(systemName: "arrow.down.circle.dotted").foregroundStyle(Ayu.accent)
                .symbolEffect(.pulse)
                .accessibilityLabel("Downloading")
        case .notDownloaded:
            Image(systemName: "icloud").foregroundStyle(.secondary)
                .accessibilityLabel("Not downloaded yet")
        }
    }
}
