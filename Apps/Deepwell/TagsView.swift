import SwiftUI
import DeepwellIndex
import DeepwellCuration

extension LibraryModel {
    /// Runs a tag curation action (file rewrites + index refresh in `TagCurator`), then refreshes the list.
    func curate(_ action: (TagCurator) throws -> CurationResult) {
        guard let curator = makeCurator() else { return }
        do {
            let result = try action(curator)
            reportCuration(result)
        } catch {
            reportCurationError("Tag change failed: \(error.localizedDescription)")
        }
    }
}

/// Tag curation screen: counts, new-tag flags, rename / merge / delete. All logic is in `TagCurator`.
struct TagsView: View {
    let model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: TagSummary?
    @State private var merging: TagSummary?
    @State private var deleting: TagSummary?
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags").font(.title2.bold())
                Spacer()
                Button("Accept All New") { model.curate { try $0.acceptAllNew() } }
                    .disabled(!model.tagSummaries.contains { $0.newCount > 0 })
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            List(model.tagSummaries, id: \.name) { tag in
                HStack {
                    Text(tag.name)
                    if tag.newCount > 0 {
                        Text("new").font(.caption2.bold()).padding(.horizontal, 5)
                            .background(.orange.opacity(0.25), in: Capsule())
                    }
                    Spacer()
                    Text("\(tag.itemCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                .contextMenu {
                    Button("Show Items") { model.tagFilter = tag.name; dismiss() }
                    Button("Rename…") { text = tag.name; renaming = tag }
                    Menu("Merge Into") {
                        ForEach(model.tagSummaries.filter { $0.name != tag.name }, id: \.name) { other in
                            Button(other.name) { merging = tag; text = other.name }
                        }
                    }
                    if tag.newCount > 0 { Button("Accept (clear new flag)") { model.curate { try $0.acceptNew(tag.name) } } }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = tag }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .alert("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $text)
            Button("Rename") { if let t = renaming { model.curate { try $0.rename(t.name, to: text) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Renaming to an existing tag merges them. Every affected file is rewritten.") }
        .confirmationDialog("Merge \"\(merging?.name ?? "")\" into \"\(text)\"?",
                            isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            Button("Merge") { if let t = merging { model.curate { try $0.merge(t.name, into: text) } } }
        }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\" from \(deleting?.itemCount ?? 0) item(s)?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Tag", role: .destructive) { if let t = deleting { model.curate { try $0.delete(t.name) } } }
        }
    }
}
