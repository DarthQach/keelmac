import SwiftUI

/// Bottom bar under lists: what's selected on the left, the one primary action on the right.
struct ActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ActionBarLayout {
                leading.tabular()
                HStack(spacing: 8) { trailing }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 16)
            .background(.kmSurface)
        }
    }
}

/// Measures two groups explicitly so a list's action bar never claims unbounded height.
private struct ActionBarLayout: Layout {
    private func measure(_ width: CGFloat, _ subviews: Subviews) -> (CGSize, CGSize, Bool) {
        let actions = subviews[1].sizeThatFits(.unspecified)
        let ideal = subviews[0].sizeThatFits(.unspecified)
        let stacked = ideal.width + actions.width + 24 > width
        let summary = subviews[0].sizeThatFits(.init(width: stacked ? width : max(0, width - actions.width - 24), height: nil))
        return (summary, actions, stacked)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let (summary, actions, stacked) = measure(width, subviews)
        return CGSize(width: width, height: stacked ? summary.height + actions.height + 12 : max(summary.height, actions.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (summary, actions, stacked) = measure(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: stacked ? bounds.minY : bounds.midY - summary.height / 2),
                          proposal: .init(width: stacked ? bounds.width : max(0, bounds.width - actions.width - 24), height: summary.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX - actions.width, y: stacked ? bounds.maxY - actions.height : bounds.midY - actions.height / 2),
                          proposal: .init(actions))
    }
}

/// Label for a primary removal button that names the size: "Move 40.1 GB to Trash" / "Delete 40.1 GB permanently".
struct RemoveLabel: View {
    let bytes: Int64
    var body: some View {
        if FileActions.deleteMode == .permanent {
            Text("Delete \(Format.bytes(bytes)) permanently")
        } else {
            Text("Move \(Format.bytes(bytes)) to Trash")
        }
    }
}

/// A checkbox row label used in previews.
struct CheckRow<Content: View>: View {
    @Binding var isOn: Bool
    var disabled = false
    @ViewBuilder var content: Content

    var body: some View {
        Toggle(isOn: $isOn) { content }
            .toggleStyle(.checkbox)
            .disabled(disabled)
    }
}
