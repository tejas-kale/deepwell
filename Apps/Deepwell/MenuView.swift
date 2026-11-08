import SwiftUI
import DeepwellMenu
import DeepwellModel

func formatMinutes(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

/// The Current Focus column: this week's bundle, or the menu of bundles when nothing is picked yet
/// (or while choosing the next one).
struct CurrentFocusView: View {
    let controller: MenuController
    let library: LibraryModel
    @Binding var selection: String?
    @Binding var browsingMenu: Bool
    var pane: FocusState<Pane?>.Binding

    var body: some View {
        if browsingMenu || controller.state.queue == nil {
            MenuView(controller: controller,
                     back: controller.state.queue == nil ? nil : { browsingMenu = false },
                     onPicked: { browsingMenu = false })
                .focusable()
                .focusEffectDisabled()
                .focused(pane, equals: .list)
        } else {
            QueueView(controller: controller, library: library, selection: $selection, browseMenu: { browsingMenu = true }, pane: pane)
        }
    }
}

/// This week's bundle in reading order. Rows open in the reader like any library item.
private struct QueueView: View {
    let controller: MenuController
    let library: LibraryModel
    @Binding var selection: String?
    let browseMenu: () -> Void
    var pane: FocusState<Pane?>.Binding

    var body: some View {
        if let q = controller.state.queue, let p = controller.progress {
            List(selection: $selection) {
                Section {
                    ForEach(Array(p.rows.enumerated()), id: \.offset) { i, row in
                        let entry = library.entry(id: row.entry.itemID)
                        QueueRow(number: i + 1, row: row, type: entry?.item.type)
                            .tag(entry?.relativePath ?? "missing:\(row.entry.itemID)")
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(q.topic).font(.title2.bold()).foregroundStyle(Ayu.text)
                        ProgressView(value: p.fraction)
                        HStack {
                            Text("\(p.doneCount) of \(p.rows.count) done · \(formatMinutes(remaining(p))) left")
                            Spacer()
                            Button("Weekly Menu", action: browseMenu)
                                .buttonStyle(.borderless)
                                .help("See this week's menu, rebuild it or pick a different bundle")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)
                    .textCase(nil)
                }
            }
            .focused(pane, equals: .list)
            .ayuSurface(Ayu.panel)
        } else {
            ContentUnavailableView("No bundle picked", systemImage: "scope", description: Text("Pick a bundle from the weekly menu."))
        }
    }

    private func remaining(_ p: QueueProgress) -> Int {
        p.rows.reduce(0) { $0 + Int((Double($1.entry.minutes) * (1 - $1.progress)).rounded()) }
    }
}

private struct QueueRow: View {
    let number: Int
    let row: QueueProgress.Row
    let type: ItemType?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.callout.monospacedDigit().bold()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.entry.title)
                    .fontWeight(row.status == .unread ? .semibold : .regular)
                    .foregroundStyle(row.status == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(Ayu.text))
                    .strikethrough(row.status == .done, color: .secondary)
                    .lineLimit(2)
                Text(row.status == nil ? "No longer in the library" : row.entry.reason)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 6) {
                    if let type { Image(systemName: type.symbol) }
                    Text(formatMinutes(row.entry.minutes))
                    if row.status == .reading { ProgressView(value: row.progress).frame(width: 40) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusIcon
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusIcon: some View {
        switch row.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Ayu.green)
        case .reading: Image(systemName: "circle.lefthalf.filled").foregroundStyle(Ayu.orange)
        case .unread: Image(systemName: "circle").foregroundStyle(.secondary)
        case nil: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// The weekly menu: 3-5 topic bundles to pick from.
struct MenuView: View {
    let controller: MenuController
    /// Back to this week's bundle; nil when nothing is picked yet.
    let back: (() -> Void)?
    let onPicked: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let back {
                        Button(action: back) { Label("This Week", systemImage: "chevron.left") }.buttonStyle(.borderless)
                    }
                    Spacer()
                    if controller.isBuilding { ProgressView().controlSize(.small) }
                    Button(controller.isBuilding ? "Building…" : (controller.state.menu == nil ? "Build Menu" : "Rebuild")) { controller.rebuild() }
                        .disabled(controller.isBuilding)
                }
                Text("Weekly Menu").font(.title2.bold()).foregroundStyle(Ayu.text)
                if let b = controller.state.menu?.builtAt {
                    Text("Built \(b.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary).padding(.top, -10)
                }
                if let e = controller.errorMessage { Text(e).foregroundStyle(Ayu.red) }
                if let menu = controller.state.menu {
                    ForEach(Array(menu.bundles.enumerated()), id: \.offset) { n, bundle in
                        BundleCard(bundle: bundle, isCurrent: controller.state.queue?.topic == bundle.topic) {
                            controller.pick(n); onPicked()
                        }
                    }
                } else if !controller.isBuilding {
                    Text("No menu yet. Build one to get up to 5 topic bundles of at most 4 hours each, made from your unread captures.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Ayu.panel)
    }
}

private struct BundleCard: View {
    let bundle: MenuBundle
    let isCurrent: Bool
    let pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bundle.topic).font(.headline).foregroundStyle(Ayu.text)
            HStack {
                Text("\(bundle.entries.count) items · \(formatMinutes(bundle.totalMinutes))").foregroundStyle(.secondary)
                Spacer()
                if isCurrent {
                    Label("This week", systemImage: "checkmark").foregroundStyle(Ayu.green)
                } else {
                    Button("Pick for This Week", action: pick)
                }
            }
            .font(.callout)
            Divider()
            ForEach(Array(bundle.entries.enumerated()), id: \.offset) { i, e in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(i + 1). \(e.title)").lineLimit(2)
                    Text("\(formatMinutes(e.minutes)) · \(e.reason)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Ayu.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isCurrent ? Ayu.accent : Ayu.chip))
    }
}
