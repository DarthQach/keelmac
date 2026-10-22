import SwiftUI

/// Secondary capacity context, with the Plimsoll mark at the existing 85% load line.
struct LoadLineGauge: View {
    let total: Int64
    let used: Int64
    var loadLine: Double = 0.85
    var height: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var fraction: Double { total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0 }
    private var marginBytes: Int64 { Int64(Double(total) * loadLine) - used }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Metrics.radiusControl)
                        .fill(.kmSurfaceMuted)
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl).strokeBorder(.kmBorder))
                    Rectangle()
                        .fill(.kmWater)
                        .overlay(alignment: .trailing) { Rectangle().fill(.kmWaterEdge).frame(width: 2) }
                        .frame(width: w * fraction)
                        .scaleEffect(x: appeared || reduceMotion ? 1 : 0.001, anchor: .leading)
                        .opacity(appeared || !reduceMotion ? 1 : 0)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Metrics.radiusControl, bottomLeadingRadius: Metrics.radiusControl))
                    Rectangle()
                        .fill(.kmHullInk)
                        .frame(width: 2)
                        .offset(x: w * loadLine - 1)
                }
            }
            .frame(height: height)

            GeometryReader { geo in
                LoadLineMark(color: .kmHullInk, lineWidth: 2)
                    .frame(width: 28, height: 16)
                    .offset(x: geo.size.width * loadLine - 14, y: 4)
            }
            .frame(height: 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.8).delay(0.15)) {
                appeared = true
            }
        }
    }

    private var accessibilityText: Text {
        let usedText = Format.bytes(used), totalText = Format.bytes(total), margin = Format.bytes(abs(marginBytes))
        return marginBytes >= 0
            ? Text("\(usedText) used of \(totalText), \(margin) above the load line")
            : Text("\(usedText) used of \(totalText), \(margin) below the load line")
    }
}

/// "38 GB above the load line" / "6 GB below the load line".
struct LoadLineSentence: View {
    let total: Int64
    let used: Int64
    var loadLine: Double = 0.85

    var body: some View {
        let margin = Int64(Double(total) * loadLine) - used
        let amount = Format.bytes(abs(margin))
        if margin >= 0 {
            Text("\(amount) above the load line")
        } else {
            Text("\(amount) below the load line")
        }
    }
}
