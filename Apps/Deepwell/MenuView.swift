import SwiftUI
import DeepwellMenu

func formatMinutes(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

/// Sheet with two tabs: this week's queue and the menu of bundles.
struct MenuContainerView: View {
    let controller: MenuController
    let close: () -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("This Week").tag(0)
                    Text("Menu").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
                Button("Done", action: close)
            }
            .padding()
            if tab == 0 { QueueView(controller: controller) } else { MenuView(controller: controller, onPicked: { tab = 0 }) }
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { controller.refresh(); if controller.state.queue == nil { tab = 1 } }
    }
}

struct MenuView: View {
    let controller: MenuController
    let onPicked: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(controller.isBuilding ? "Building…" : "Rebuild menu") { controller.rebuild() }
                        .disabled(controller.isBuilding)
                    if controller.isBuilding { ProgressView().controlSize(.small) }
                    if let b = controller.state.menu?.builtAt {
                        Text("Built \(b.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let e = controller.errorMessage { Text(e).foregroundStyle(.red) }
                if let menu = controller.state.menu {
                    ForEach(Array(menu.bundles.enumerated()), id: \.offset) { n, bundle in
                        BundleCard(bundle: bundle) { controller.pick(n); onPicked() }
                    }
                } else if !controller.isBuilding {
                    Text("No menu yet. Rebuild to get 3-5 topic bundles of about 5 hours each.").foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

private struct BundleCard: View {
    let bundle: MenuBundle
    let pick: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(bundle.topic).font(.headline)
                    Spacer()
                    Text(formatMinutes(bundle.totalMinutes)).foregroundStyle(.secondary)
                    Button("Pick this week", action: pick)
                }
                ForEach(Array(bundle.entries.enumerated()), id: \.offset) { i, e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(i + 1). \(e.title)  (\(formatMinutes(e.minutes)))")
                        Text(e.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }
}

struct QueueView: View {
    let controller: MenuController

    var body: some View {
        if let q = controller.state.queue, let p = controller.progress {
            VStack(alignment: .leading, spacing: 12) {
                Text(q.topic).font(.title2.bold())
                ProgressView(value: p.fraction) { Text("\(p.doneCount) of \(p.rows.count) done") }
                List(Array(p.rows.enumerated()), id: \.offset) { i, r in
                    HStack {
                        Image(systemName: r.status == .done ? "checkmark.circle.fill" : (r.status == nil ? "questionmark.circle" : "circle"))
                        VStack(alignment: .leading) {
                            Text("\(i + 1). \(r.entry.title)")
                            Text(r.status == nil ? "No longer in library" : r.entry.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatMinutes(r.entry.minutes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding([.horizontal, .bottom])
        } else {
            ContentUnavailableView("No queue yet", systemImage: "list.number", description: Text("Pick a bundle from the menu."))
        }
    }
}
