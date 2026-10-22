import SwiftUI

/// Colours come from the asset catalog, which `scripts/tokens.mjs` generates from design/tokens.css.
/// Never use raw colour values in views.
extension ShapeStyle where Self == Color {
    static var kmBg: Color { Color("bg") }
    static var kmSurface: Color { Color("surface") }
    static var kmSurfaceMuted: Color { Color("surfaceMuted") }
    static var kmBorder: Color { Color("border") }
    static var kmBorderStrong: Color { Color("borderStrong") }
    static var kmFg: Color { Color("fg") }
    static var kmFgMuted: Color { Color("fgMuted") }
    static var kmAccent: Color { Color("AccentColor") }
    static var kmAccentSoft: Color { Color("accentSoft") }
    static var kmAccentText: Color { Color("accentText") }
    static var kmOnAccent: Color { Color("onAccent") }
    static var kmWater: Color { Color("water") }
    static var kmWaterEdge: Color { Color("waterEdge") }
    static var kmHullInk: Color { Color("hullInk") }
    static var kmSuccess: Color { Color("success") }
    static var kmWarning: Color { Color("warning") }
    static var kmDanger: Color { Color("danger") }
    static var kmDangerSolid: Color { Color("dangerSolid") }
    static var kmWarningSoft: Color { Color("warningSoft") }
    static var kmWarningInk: Color { Color("warningInk") }
    static var kmKindMedia: Color { Color("kindMedia") }
    static var kmKindArchive: Color { Color("kindArchive") }
    static var kmKindModel: Color { Color("kindModel") }
    static var kmOnKind: Color { Color("onKind") }
}

enum Metrics {
    static let radiusControl: CGFloat = 6
    static let radius: CGFloat = 10
    static let pagePadding: CGFloat = 24
    static let contentMaxWidth: CGFloat = 1100
}

extension View {
    /// Tabular figures for every number that changes or lines up.
    func tabular() -> some View { monospacedDigit() }

    /// A grouped surface: 1px border, no shadow (borders for structure).
    func kmGroup(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(.kmSurface, in: RoundedRectangle(cornerRadius: Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(.kmBorder))
    }
}

/// Primary action: verdigris fill, used once per view.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.kmOnAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.kmAccent.opacity(isEnabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var kmPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// Byte and number formatting in the user's locale.
enum Format {
    static func bytes(_ value: Int64) -> String {
        let binary = UserDefaults.standard.string(forKey: Preferences.Key.byteUnits) == "binary"
        let f = ByteCountFormatter()
        f.countStyle = binary ? .memory : .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: value)
    }

    static func bytes(_ value: UInt64) -> String { bytes(Int64(clamping: value)) }

    /// RAM sizes use binary units, as Activity Monitor and About This Mac do.
    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    /// Bytes per second, e.g. "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(bytesPerSecond.rounded())))/s"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        fraction.formatted(.percent.precision(.fractionLength(digits)))
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    static func temperature(_ celsius: Double) -> String {
        let fahrenheit = UserDefaults.standard.string(forKey: Preferences.Key.temperatureUnit) == "fahrenheit"
        let m = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: fahrenheit ? .fahrenheit : .celsius)
        return m.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
