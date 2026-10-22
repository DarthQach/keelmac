import SwiftUI

/// Bottom bar under lists: what's selected on the left, the one primary action on the right.
struct ActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                leading
                    .tabular()
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 10)
            .background(.kmBg)
        }
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
