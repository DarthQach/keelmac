import SwiftUI

struct PageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(.kmFgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }
}

/// Four metrics stay in a predictable two- or four-column rhythm, with intrinsic heights.
struct MetricColumns: Layout {
    var gap: CGFloat = Metrics.panelGap

    private func dimensions(_ width: CGFloat, _ subviews: Subviews) -> (Int, CGFloat, [CGFloat]) {
        let columns = width >= 840 ? 4 : 2
        let cellWidth = max(0, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count)).map {
                subviews[$0].sizeThatFits(.init(width: cellWidth, height: nil)).height
            }.max() ?? 0
        }
        return (columns, cellWidth, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 840
        let (_, _, heights) = dimensions(width, subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, width, heights) = dimensions(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (width + gap), y: y),
                                     proposal: .init(width: width, height: height))
            }
            y += height + gap
        }
    }
}

/// Identity and location occupy separate lines; sizes and status stay in their own columns.
struct FileIdentity: View {
    let name: String
    var path: String? = nil
    var symbol: String = "doc"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.kmFgMuted).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if let path { PathText(path: path) }
            }
        }
        .help(path ?? name)
        .frame(minHeight: path == nil ? Metrics.rowHeight : Metrics.detailRowHeight, alignment: .leading)
    }
}

extension View {
    func kmTableSurface() -> some View {
        self.scrollContentBackground(.hidden)
            .background(.kmSurface)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(.kmBorder))
    }
}

/// Keeps legends and small filter groups readable as the workspace narrows.
struct WrappingRow: Layout {
    var spacing: CGFloat = 12

    private func arrangement(width: CGFloat, subviews: Subviews) -> ([CGRect], CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).1)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).0
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }
}
