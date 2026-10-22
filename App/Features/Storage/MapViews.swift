import ScanKit
import SwiftUI

/// One rectangle of the treemap. `id == nil` is the "small files" remainder of a folder.
struct Tile: Identifiable {
    let id: Int
    let node: NodeID?
    let rect: CGRect
    let depth: Int
    let isDirectory: Bool
    let name: String
    let bytes: Int64
}

/// Squarified treemap, two levels deep, drawn with Canvas (C8).
struct TreemapView: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: NodeID?
    let open: (NodeID) -> Void

    var body: some View {
        GeometryReader { geo in
            let tiles = Self.layout(tree: tree, root: root, in: CGRect(origin: .zero, size: geo.size))
            Canvas { ctx, _ in
                for t in tiles { draw(t, in: &ctx) }
            }
            .background(.kmSurfaceMuted, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in if let n = hit(tiles, v.location) { open(n) } }
                    .exclusively(before: SpatialTapGesture().onEnded { v in selection = hit(tiles, v.location) })
            )
            .contextMenu {
                if let s = selection {
                    Button("Reveal in Finder") { FileActions.reveal([tree.path(of: s)]) }
                }
            }
        }
    }

    private func hit(_ tiles: [Tile], _ p: CGPoint) -> NodeID? {
        tiles.filter { $0.node != nil && $0.rect.contains(p) }.max { $0.depth < $1.depth }?.node
    }

    private func draw(_ t: Tile, in ctx: inout GraphicsContext) {
        let r = t.rect.insetBy(dx: 1, dy: 1)
        guard r.width > 1, r.height > 1 else { return }
        let fill: Color
        switch (t.depth, t.isDirectory, t.node == nil) {
        case (_, _, true): fill = Color.kmSurface
        case (1, true, _): fill = Color.kmWater.opacity(0.55)
        case (1, false, _): fill = Color.kmWater.opacity(0.35)
        case (_, true, _): fill = Color.kmWater.opacity(0.95)
        default: fill = Color.kmWater.opacity(0.7)
        }
        ctx.fill(Path(r), with: .color(fill))
        if let n = t.node, n == selection {
            ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(.kmAccent), lineWidth: 2.5)
        }
        guard r.width > 56, r.height > 30 else { return }
        let name = Text(verbatim: t.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.kmFg)
        let size = Text(Format.bytes(t.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.kmFg)
        let resolvedName = ctx.resolve(name)
        let nameSize = resolvedName.measure(in: CGSize(width: r.width - 12, height: 16))
        ctx.draw(resolvedName, in: CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 12, height: nameSize.height))
        let resolvedSize = ctx.resolve(size)
        let sizeWidth = resolvedSize.measure(in: CGSize(width: r.width, height: 16)).width
        let headerFits = nameSize.width + sizeWidth + 18 < r.width
        if t.depth == 1 && t.isDirectory && r.height >= 60 && headerFits {
            ctx.draw(resolvedSize, at: CGPoint(x: r.maxX - 6, y: r.minY + 4), anchor: .topTrailing)
        } else if r.height > 44 {
            ctx.draw(resolvedSize, at: CGPoint(x: r.minX + 6, y: r.maxY - 6), anchor: .bottomLeading)
        }
    }

    static func layout(tree: ScanTree, root: NodeID, in bounds: CGRect) -> [Tile] {
        var tiles: [Tile] = []
        var nextID = 0
        func place(parent: NodeID, rect: CGRect, depth: Int, limit: Int) {
            let ids = Array(tree.children(of: parent).prefix(limit))
            var sizes = ids.map { Double(tree.bytes(of: $0)) }
            let small = tree.smallFilesBytes(of: parent)
            let shown = sizes.reduce(0, +)
            let rest = Double(tree.bytes(of: parent)) - shown
            let remainder = max(Double(small), rest)
            if remainder > shown * 0.01 { sizes.append(remainder) }
            guard sizes.reduce(0, +) > 0 else { return }
            let rects = TreemapLayout.squarify(sizes: sizes, in: rect)
            for (i, r) in rects.enumerated() {
                let node: NodeID? = i < ids.count ? ids[i] : nil
                let isDir = node.map(tree.isDirectory) ?? false
                let name = node.map(tree.name(of:)) ?? String(localized: "Other files")
                tiles.append(Tile(id: nextID, node: node, rect: r, depth: depth, isDirectory: isDir, name: name, bytes: Int64(sizes[i])))
                nextID += 1
                if depth == 1, let node, isDir, r.width > 90, r.height > 70, tree.childCount(of: node) > 0 {
                    place(parent: node, rect: CGRect(x: r.minX + 6, y: r.minY + 24, width: r.width - 12, height: r.height - 30), depth: 2, limit: 40)
                }
            }
        }
        place(parent: root, rect: bounds, depth: 1, limit: 60)
        return tiles
    }
}

/// Sunburst: rings by depth, angles by size (C8, v2).
struct SunburstView: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: NodeID?
    let open: (NodeID) -> Void
    private let maxDepth = 4
    @State private var hovered: NodeID?

    var body: some View {
        GeometryReader { geo in
            let segments = SunburstLayout.layout(tree: tree, root: root, maxDepth: maxDepth, minAngle: 0.012)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2 - 8
            let ring = radius / CGFloat(maxDepth + 1)
            ZStack {
                Canvas { ctx, _ in
                    for s in segments {
                        let inner = ring * CGFloat(s.depth), outer = inner + ring - 1.5
                        var p = Path()
                        p.addArc(center: center, radius: outer, startAngle: .radians(s.startAngle - .pi / 2), endAngle: .radians(s.endAngle - .pi / 2), clockwise: false)
                        p.addArc(center: center, radius: inner, startAngle: .radians(s.endAngle - .pi / 2), endAngle: .radians(s.startAngle - .pi / 2), clockwise: true)
                        p.closeSubpath()
                        let opacity = max(0.35, 1.0 - Double(s.depth - 1) * 0.17)
                        ctx.fill(p, with: .color(tree.isDirectory(s.id) ? Color.kmWater.opacity(opacity) : Color.kmSurface))
                        ctx.stroke(p, with: .color(.kmBg), lineWidth: 1)
                        if s.id == selection { ctx.stroke(p, with: .color(.kmAccent), lineWidth: 2.5) }
                    }
                }
                VStack(spacing: 2) {
                    Text(verbatim: tree.name(of: hovered ?? selection ?? root)).fontWeight(.semibold).lineLimit(2)
                    Text(Format.bytes(tree.bytes(of: hovered ?? selection ?? root))).foregroundStyle(.kmFgMuted).tabular()
                }
                .frame(width: max(40, ring * 1.8))
                .multilineTextAlignment(.center)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hovered = hit(segments, p, center, ring) } else { hovered = nil }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { v in if let n = hit(segments, v.location, center, ring) { open(n) } }
                    .exclusively(before: SpatialTapGesture().onEnded { v in selection = hit(segments, v.location, center, ring) })
            )
        }
    }

    private func hit(_ segments: [SunburstSegment], _ p: CGPoint, _ c: CGPoint, _ ring: CGFloat) -> NodeID? {
        let dx = p.x - c.x, dy = p.y - c.y
        let r = (dx * dx + dy * dy).squareRoot()
        let depth = Int(r / ring)
        guard depth >= 1 else { return nil }
        var angle = atan2(Double(dy), Double(dx)) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return segments.first { $0.depth == depth && angle >= $0.startAngle && angle < $0.endAngle }?.id
    }
}
