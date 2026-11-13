import SwiftUI
import DeepwellIndex
import DeepwellCuration

/// What the tag curation screen needs from the app's library model. The Mac's `LibraryModel` and the phone's
/// `FocusLibrary` (ticket 19) conform.
@MainActor
public protocol TagsModel: AnyObject {
    var tagSummaries: [TagSummary] { get }
    /// Runs a curation action (file rewrites + index refresh in `TagCurator`), then refreshes the list.
    /// Nil when the library has no index, or the action threw.
    @discardableResult
    func curate(_ action: (TagCurator) throws -> CurationResult) -> CurationResult?
    /// "Show Items": switch the library to the items carrying `tag`.
    func showItems(tagged tag: String)
}

/// Tag curation screen: counts, new-tag flags, rename / merge / delete / accept. All logic is in `TagCurator`.
/// Shown as a sheet on both platforms. Actions sit in each row's context menu (right-click on the Mac, long press on
/// iOS); on iOS rows also swipe: Rename and Accept from the leading edge, Delete from the trailing edge.
public struct TagsView<Model: TagsModel>: View {
    let model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: TagSummary?
    @State private var merging: TagSummary?
    @State private var deleting: TagSummary?
    @State private var text = ""
    /// Rows captured after a curation action. Set explicitly so the list updates even when the model is observed
    /// through `TagsModel` and SwiftUI doesn't invalidate the body.
    @State private var pinnedSummaries: [TagSummary]?
    /// Banner after Accept All New. Nil hides it.
    @State private var acceptNotice: TagAcceptAllFeedback?
    @State private var acceptNoticeID = 0

    public init(model: Model) { self.model = model }

    private var rows: [TagSummary] { pinnedSummaries ?? model.tagSummaries }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags").font(.title2.bold())
                Spacer()
                Button("Accept All New") { acceptAllNew() }
                    .disabled(!rows.contains { $0.newCount > 0 })
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            if let acceptNotice {
                TagAcceptBanner(feedback: acceptNotice)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            List(rows, id: \.name) { tag in
                HStack {
                    Text(tag.name)
                    if tag.newCount > 0 {
                        Text("new").font(.caption2.bold()).padding(.horizontal, 5)
                            .background(Ayu.accent.opacity(0.3), in: Capsule())
                    }
                    Spacer()
                    Text("\(tag.itemCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                .contextMenu {
                    Button("Show Items") { model.showItems(tagged: tag.name); dismiss() }
                    Button("Rename…") { text = tag.name; renaming = tag }
                    Menu("Merge Into") {
                        ForEach(rows.filter { $0.name != tag.name }, id: \.name) { other in
                            Button(other.name) { merging = tag; text = other.name }
                        }
                    }
                    if tag.newCount > 0 { Button("Accept (clear new flag)") { perform { try $0.acceptNew(tag.name) } } }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = tag }
                }
                #if os(iOS)
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { deleting = tag }
                }
                .swipeActions(edge: .leading) {
                    Button("Rename") { text = tag.name; renaming = tag }.tint(Ayu.blue)
                    if tag.newCount > 0 {
                        Button("Accept") { perform { try $0.acceptNew(tag.name) } }.tint(Ayu.green)
                    }
                }
                #endif
            }
            .ayuSurface(Ayu.background)
        }
        .background(Ayu.panel)
        .animation(.snappy, value: acceptNotice?.message)
        .task(id: acceptNoticeID) {
            guard acceptNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { acceptNotice = nil }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .alert("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $text)
            Button("Rename") { if let t = renaming { perform { try $0.rename(t.name, to: text) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Renaming to an existing tag merges them. Every affected file is rewritten.") }
        .confirmationDialog("Merge \"\(merging?.name ?? "")\" into \"\(text)\"?",
                            isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            Button("Merge") { if let t = merging { perform { try $0.merge(t.name, into: text) } } }
        }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\" from \(deleting?.itemCount ?? 0) item(s)?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Tag", role: .destructive) { if let t = deleting { perform { try $0.delete(t.name) } } }
        }
    }

    private func perform(_ action: (TagCurator) throws -> CurationResult) {
        _ = model.curate(action)
        pinnedSummaries = model.tagSummaries
    }

    private func acceptAllNew() {
        let before = rows
        let result = model.curate { try $0.acceptAllNew() }
        guard let feedback = TagAcceptAllFeedback.make(before: before, after: model.tagSummaries, result: result) else { return }
        pinnedSummaries = feedback.summaries
        acceptNotice = feedback
        acceptNoticeID += 1
        TagAcceptFeedbackPlayer.play(feedback)
    }
}

/// Confirmation after Accept All New: a short banner. On iPhone it sits with the haptic from
/// `TagAcceptFeedbackPlayer`.
private struct TagAcceptBanner: View {
    let feedback: TagAcceptAllFeedback

    var body: some View {
        let symbol = switch feedback.haptic {
        case .success: "checkmark.circle.fill"
        case .warning, .error: "exclamationmark.triangle.fill"
        }
        Label(feedback.message, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(feedback.haptic == .error ? Ayu.red : Ayu.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .accessibilityLabel(feedback.message)
    }
}
