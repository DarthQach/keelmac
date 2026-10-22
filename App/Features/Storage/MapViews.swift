import ScanKit
import SwiftUI

/// Review candidates on the map: their nodes, plus every ancestor so the path to them stays visible.
struct MapHighlight {
    let candidates: Set<NodeID>
    let lit: Set<NodeID>

    init(items: [ReviewItem], tree: ScanTree) {
        let candidates = Set(items.flatMap(\.nodes))
        var lit = candidates
        for id in candidates {
            // Stop at the first ancestor another candidate already lit.
            var p = tree.parent(of: id)
            while let a = p, lit.insert(a).inserted { p = tree.parent(of: a) }
        }
        self.candidates = candidates
        self.lit = lit
    }

    func isInsideCandidate(_ id: NodeID, tree: ScanTree) -> Bool {
        tree.ancestors(of: id).contains(where: candidates.contains)
    }
}


struct Tile: Identifiable {
    var id: MapItem { item }
    let item: MapItem
    let rect: CGRect
    let labelRect: CGRect
    let depth: Int
    let bytes: Int64
    let hasChildren: Bool
}

/// Geometry is calculated once, then shared by drawing, hover and click handling.
struct TreemapView: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: MapItem?
    @Binding var hovered: MapItem?
    var highlight: MapHighlight?
    var colors: KindShares?
    let open: (NodeID) -> Void

    var body: some View {
        GeometryReader { geo in
            let tiles = Self.layout(tree: tree, root: root, in: CGRect(origin: .zero, size: geo.size))
            Canvas { ctx, _ in
                for tile in tiles { draw(tile, in: &ctx) }
                let target = MapPresentation.target(for: selection, among: tiles.map(\.item), tree: tree)
                for tile in tiles {
                    let selected = target == tile.item
                    if selected || tile.item == hovered {
                        ctx.stroke(Path(roundedRect: tile.rect.insetBy(dx: 2, dy: 2), cornerRadius: 5),
                                   with: .color(selected ? .kmAccentText : .kmFgMuted), lineWidth: selected ? 3 : 1.5)
                    }
                }
            }
            .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { hovered = Self.hit(tiles, point) } else { hovered = nil }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                if let item = Self.hit(tiles, value.location) { selection = item; if let node = item.node { open(node) } }
            }.exclusively(before: SpatialTapGesture().onEnded { value in selection = Self.hit(tiles, value.location) }))
            .accessibilityHidden(true)
        }
    }

    static func hit(_ tiles: [Tile], _ point: CGPoint) -> MapItem? {
        tiles.last { Path(roundedRect: $0.rect, cornerRadius: 5).contains(point) }?.item
    }

    private func draw(_ tile: Tile, in ctx: inout GraphicsContext) {
        let r = tile.rect
        guard r.width > 1, r.height > 1 else { return }
        ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(MapPaint.fill(tile.item, depth: tile.depth, tree: tree, colors: colors, highlight: highlight)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(.kmBorder), lineWidth: 0.5)
        let label = tile.labelRect.insetBy(dx: 8, dy: 4)
        guard label.width >= 64, label.height >= 30 else { return }
        var textContext = ctx
        textContext.clip(to: Path(tile.labelRect))
        let name = MapLabel.fitted(tile.item.name(in: tree), width: label.width, context: ctx)
        let resolved = ctx.resolve(Text(verbatim: name).font(.callout.weight(.semibold)).foregroundStyle(.kmFg))
        textContext.draw(resolved, at: CGPoint(x: label.minX, y: label.minY), anchor: .topLeading)
        let size = ctx.resolve(Text(Format.bytes(tile.bytes)).font(.caption).monospacedDigit().foregroundStyle(.kmFg))
        let nameHeight = resolved.measure(in: CGSize(width: label.width, height: .infinity)).height
        let sizeMeasurement = size.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        if sizeMeasurement.width <= label.width && nameHeight + sizeMeasurement.height + 2 <= label.height {
            textContext.draw(size, at: CGPoint(x: label.minX, y: label.minY + nameHeight + 2), anchor: .topLeading)
        }
    }

    static func layout(tree: ScanTree, root: NodeID, in bounds: CGRect) -> [Tile] {
        var result: [Tile] = []
        func place(_ entries: [MapEntry], in bounds: CGRect, depth: Int) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let rects = TreemapLayout.squarify(sizes: entries.map { Double($0.bytes) }, in: bounds)
            for (entry, raw) in zip(entries, rects) {
                let rect = raw.insetBy(dx: 2, dy: 2)
                guard rect.width > 0, rect.height > 0 else { continue }
                let nests = !entry.children.isEmpty && rect.width >= 160 && rect.height >= 132
                let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: nests ? 40 : rect.height)
                result.append(Tile(item: entry.item, rect: rect, labelRect: header, depth: depth, bytes: entry.bytes, hasChildren: nests))
                if nests {
                    place(entry.children, in: CGRect(x: rect.minX + 4, y: rect.minY + 40, width: rect.width - 8, height: rect.height - 44), depth: depth + 1)
                }
            }
        }
        place(MapPresentation(tree: tree, root: root).entries, in: bounds, depth: 1)
        return result
    }
}

/// Explicit truncation avoids Canvas text wrapping through a parent's reserved header.
enum MapLabel {
    static func fitted(_ text: String, width: CGFloat, context: GraphicsContext) -> String {
        func fits(_ string: String) -> Bool {
            context.resolve(Text(verbatim: string).font(.callout.weight(.semibold)))
                .measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width <= width
        }
        if fits(text) { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(String(chars.prefix(mid)) + "…") { lo = mid } else { hi = mid - 1 }
        }
        return String(chars.prefix(lo)) + "…"
    }
}

struct MapArc: Identifiable {
    var id: MapItem { item }
    let item: MapItem
    let depth: Int
    let start: Double
    let end: Double
    let inner: CGFloat
    let outer: CGFloat

    func path(center: CGPoint) -> Path {
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start - .pi / 2), endAngle: .radians(end - .pi / 2), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(end - .pi / 2), endAngle: .radians(start - .pi / 2), clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct SunburstView: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: MapItem?
    @Binding var hovered: MapItem?
    var highlight: MapHighlight?
    var colors: KindShares?
    let open: (NodeID) -> Void

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = max(0, min(geo.size.width, geo.size.height) / 2 - 8)
            let arcs = Self.layout(tree: tree, root: root, radius: radius)
            ZStack {
                Canvas { ctx, _ in
                    for arc in arcs {
                        let path = arc.path(center: center)
                        ctx.fill(path, with: .color(MapPaint.fill(arc.item, depth: arc.depth, tree: tree, colors: colors, highlight: highlight)))
                        ctx.stroke(path, with: .color(.kmSurface), lineWidth: 2)
                    }
                    let target = MapPresentation.target(for: selection, among: arcs.map(\.item), tree: tree)
                    for arc in arcs {
                        let selected = target == arc.item
                        if selected || arc.item == hovered {
                            ctx.stroke(arc.path(center: center), with: .color(selected ? .kmAccentText : .kmFgMuted), lineWidth: selected ? 3 : 1.5)
                        }
                    }
                }
                VStack(spacing: 8) {
                    Image(systemName: root == tree.root ? "internaldrive" : "folder").foregroundStyle(.kmFgMuted)
                    Text(verbatim: tree.name(of: root)).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(Format.bytes(tree.bytes(of: root))).font(.caption).foregroundStyle(.kmFgMuted).tabular().lineLimit(1)
                }
                .frame(width: radius * 0.64)
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { hovered = Self.hit(arcs, point, center: center) } else { hovered = nil }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                if let item = Self.hit(arcs, value.location, center: center) { selection = item; if let node = item.node { open(node) } }
            }.exclusively(before: SpatialTapGesture().onEnded { value in selection = Self.hit(arcs, value.location, center: center) }))
            .accessibilityHidden(true)
        }
    }

    static func layout(tree: ScanTree, root: NodeID, radius: CGFloat) -> [MapArc] {
        guard radius > 0, tree.bytes(of: root) > 0 else { return [] }
        var arcs: [MapArc] = []
        func place(_ entries: [MapEntry], total: Int64, start: Double, span: Double, depth: Int) {
            guard total > 0 else { return }
            var angle = start
            for entry in entries {
                let end = min(start + span, angle + span * Double(entry.bytes) / Double(total))
                arcs.append(MapArc(item: entry.item, depth: depth, start: angle, end: end,
                                   inner: radius * (depth == 1 ? 0.4 : 0.7), outer: radius * (depth == 1 ? 0.68 : 1)))
                if !entry.children.isEmpty { place(entry.children, total: entry.bytes, start: angle, span: end - angle, depth: 2) }
                angle = end
            }
        }
        place(MapPresentation(tree: tree, root: root).entries, total: tree.bytes(of: root), start: 0, span: 2 * .pi, depth: 1)
        return arcs
    }

    static func hit(_ arcs: [MapArc], _ point: CGPoint, center: CGPoint) -> MapItem? {
        arcs.first { $0.path(center: center).contains(point) }?.item
    }
}

private enum MapPaint {
    static func fill(_ item: MapItem, depth: Int, tree: ScanTree, colors: KindShares?, highlight: MapHighlight?) -> Color {
        guard let node = item.node else { return .kmSurfaceMuted }
        let branch = depth == 2 ? (tree.parent(of: node) ?? node) : node
        let kindColor = colors?.group(of: branch, in: tree)?.color
        let base = kindColor ?? Color.kmWater
        if let highlight {
            if highlight.candidates.contains(node) { return .kmAccentSoft }
            if highlight.isInsideCandidate(node, tree: tree) { return .kmAccentSoft }
            if !highlight.lit.contains(node) { return .kmSurfaceMuted }
        }
        // Composited onto the panel; ink remains the semantic foreground, never white on pale hues.
        return base.opacity(kindColor == nil ? (depth == 1 ? 0.75 : 0.5) : (depth == 1 ? 0.24 : 0.14))
    }
}
