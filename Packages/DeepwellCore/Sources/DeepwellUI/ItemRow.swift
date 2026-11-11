import SwiftUI
import DeepwellModel
import DeepwellIndex

/// One library row (ticket 19 moved it here from the Mac app so the phone's Library uses it too): title (bold when
/// unread), snippet or summary, tag chips with the new-tag mark, capture date and a progress bar while reading. The
/// type icon carries the status badge. `typeSymbol` is the app's SF Symbol for the item type.
public struct ItemRow: View {
    let entry: IndexedItem
    let typeSymbol: String

    public init(entry: IndexedItem, typeSymbol: String) {
        self.entry = entry
        self.typeSymbol = typeSymbol
    }

    public var body: some View {
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
        Image(systemName: typeSymbol)
            .font(.title3).foregroundStyle(.secondary).frame(width: 26, height: 26)
            .overlay(alignment: .topTrailing) { StatusBadge(status: entry.item.status) }
            .help(entry.item.status.rawValue.capitalized)
    }
}

public struct StatusBadge: View {
    let status: ItemStatus

    public init(status: ItemStatus) { self.status = status }

    public var body: some View {
        switch status {
        case .unread: Circle().fill(Ayu.blue).frame(width: 9, height: 9).offset(x: 3, y: -2)
        case .reading: Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)).foregroundStyle(Ayu.orange).offset(x: 4, y: -3)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Ayu.green).offset(x: 4, y: -3)
        }
    }
}

/// Left-to-right layout that wraps onto new lines, so tags are never truncated to "age…".
public struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    public init(spacing: CGFloat = 4) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
