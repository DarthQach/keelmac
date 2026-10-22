import ScanKit
import SwiftUI

/// One rectangle of the treemap. `node == nil` is the "small files" remainder of a folder.
/// `hasChildren` tiles draw a header row with their contents nested below it.
struct Tile: Identifiable {
    let id: Int
    let node: NodeID?
    let rect: CGRect
    let depth: Int
    let isDirectory: Bool
    let hasChildren: Bool
    let name: String
    let bytes: Int64
    var role: TileRole = .normal
}

/// How a tile draws while the map highlights review candidates.
enum TileRole {
    case normal
    /// A review candidate (a large file or a whole model folder).
    case candidate
    /// Inside a candidate folder.
    case insideCandidate
    /// Holds no candidate.
    case dimmed
}

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

/// Squarified treemap, nested as deep as the space allows, drawn with Canvas (C8).
struct TreemapView: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: NodeID?
    var highlight: MapHighlight?
    var colors: KindShares?
    let open: (NodeID) -> Void

    static let maxDepth = 5
    static let maxTiles = 4000

    var body: some View {
        GeometryReader { geo in
            let tiles = Self.layout(tree: tree, root: root, in: CGRect(origin: .zero, size: geo.size), highlight: highlight)
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
        // Deeper folders are a shade stronger so nested levels stay apart.
        var fill: Color
        switch (t.node == nil, t.isDirectory) {
        case (true, _): fill = Color.kmWater.opacity(0.12)
        case (_, true): fill = Color.kmWater.opacity(min(0.95, 0.35 + 0.12 * Double(t.depth)))
        default: fill = Color.kmWater.opacity(min(0.75, 0.2 + 0.12 * Double(t.depth)))
        }
        var ink = Color.kmFg
        // File kinds: solid colour on files, a tint on folders mostly made of one kind, stripes for documents.
        let group = t.node.flatMap { colors?.group(of: $0, in: tree) }
        var tint: Color?
        if let kind = group?.color {
            if t.isDirectory { tint = kind.opacity(min(0.65, 0.35 + 0.08 * Double(t.depth))) } else { fill = kind; ink = .kmOnKind }
        }
        switch t.role {
        case .normal: break
        case .candidate: fill = .kmAccent; ink = .kmOnAccent; tint = nil
        case .insideCandidate: fill = .kmAccentSoft; ink = .kmFg; tint = nil
        case .dimmed: ctx.opacity = 0.22
        }
        defer { ctx.opacity = 1 }
        if let tint {
            ctx.fill(Path(r), with: .color(.kmSurfaceMuted))
            ctx.fill(Path(r), with: .color(tint))
        } else {
            ctx.fill(Path(r), with: .color(fill))
        }
        if group == .document, t.role == .normal || t.role == .dimmed { Self.stripes(r, in: ctx) }
        if let n = t.node, n == selection {
            ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(.kmAccent), lineWidth: 2.5)
        }
        guard r.width > 56, r.height > 30 else { return }
        let name = Text(verbatim: t.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
        let size = Text(Format.bytes(t.bytes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(ink)
        let resolvedName = ctx.resolve(name)
        let nameSize = resolvedName.measure(in: CGSize(width: r.width - 12, height: 16))
        ctx.draw(resolvedName, in: CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 12, height: nameSize.height))
        let resolvedSize = ctx.resolve(size)
        let sizeWidth = resolvedSize.measure(in: CGSize(width: r.width, height: 16)).width
        let headerFits = nameSize.width + sizeWidth + 18 < r.width
        if t.hasChildren && headerFits {
            ctx.draw(resolvedSize, at: CGPoint(x: r.maxX - 6, y: r.minY + 4), anchor: .topTrailing)
        } else if !t.hasChildren && r.height > 44 {
            // A nesting tile's bottom edge is covered by its children, so only leaf tiles show the size there.
            ctx.draw(resolvedSize, at: CGPoint(x: r.minX + 6, y: r.maxY - 6), anchor: .bottomLeading)
        }
    }

    /// 45° hairlines: the documents texture (a fourth hue would not stay distinguishable).
    static func stripes(_ r: CGRect, in ctx: GraphicsContext, color: Color = .kmFgMuted) {
        var c = ctx
        c.clip(to: Path(r))
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 6
        }
        c.stroke(p, with: .color(color.opacity(0.35)), lineWidth: 1)
    }

    /// Follows a folder down while one child folder holds at least 95% of it, so
    /// `Users › novfrost` takes one level instead of two near-identical blocks.
    static func chain(from id: NodeID, in tree: ScanTree) -> [NodeID] {
        var path = [id]
        while let last = path.last, tree.isDirectory(last), let first = tree.children(of: last).first,
              tree.isDirectory(first), tree.childCount(of: first) > 0,
              Double(tree.bytes(of: first)) >= Double(tree.bytes(of: last)) * 0.95 {
            path.append(first)
        }
        return path
    }

    static func layout(tree: ScanTree, root: NodeID, in bounds: CGRect, highlight: MapHighlight? = nil) -> [Tile] {
        var tiles: [Tile] = []
        func role(_ path: [NodeID], insideCandidate: Bool) -> TileRole {
            guard let highlight else { return .normal }
            if insideCandidate { return .insideCandidate }
            if path.contains(where: highlight.candidates.contains) { return .candidate }
            return path.contains(where: highlight.lit.contains) ? .normal : .dimmed
        }
        // `container` sets the size; `content` (the end of its chain) supplies the children.
        // Whatever the children don't cover becomes the "Other files" tile.
        func place(container: NodeID, content: NodeID, rect: CGRect, depth: Int, insideCandidate: Bool) {
            let ids = Array(tree.children(of: content).prefix(depth == 1 ? 60 : 40))
            var sizes = ids.map { Double(tree.bytes(of: $0)) }
            let shown = sizes.reduce(0, +)
            let remainder = max(Double(tree.smallFilesBytes(of: content)), Double(tree.bytes(of: container)) - shown)
            if remainder > shown * 0.01 { sizes.append(remainder) }
            guard sizes.reduce(0, +) > 0 else { return }
            for (i, r) in TreemapLayout.squarify(sizes: sizes, in: rect).enumerated() {
                guard tiles.count < maxTiles else { return }
                guard i < ids.count else {
                    tiles.append(Tile(id: tiles.count, node: nil, rect: r, depth: depth, isDirectory: false, hasChildren: false,
                                      name: String(localized: "Other files"), bytes: Int64(sizes[i]),
                                      role: highlight == nil ? .normal : insideCandidate ? .insideCandidate : .dimmed))
                    continue
                }
                let node = ids[i]
                let isDir = tree.isDirectory(node)
                let path = isDir ? chain(from: node, in: tree) : [node]
                let inner = path[path.count - 1]
                let nests = isDir && depth < maxDepth && r.width > 90 && r.height > 70 && tree.childCount(of: inner) > 0
                let tileRole = role(path, insideCandidate: insideCandidate)
                tiles.append(Tile(id: tiles.count, node: inner, rect: r, depth: depth, isDirectory: isDir, hasChildren: nests,
                                  name: path.map(tree.name(of:)).joined(separator: " › "), bytes: Int64(sizes[i]), role: tileRole))
                if nests {
                    place(container: node, content: inner,
                          rect: CGRect(x: r.minX + 6, y: r.minY + 24, width: r.width - 12, height: r.height - 30), depth: depth + 1,
                          insideCandidate: tileRole == .candidate || tileRole == .insideCandidate)
                }
            }
        }
        let path = chain(from: root, in: tree)
        let rootInside = highlight.map { h in path.contains(where: h.candidates.contains) || h.isInsideCandidate(root, tree: tree) } ?? false
        place(container: root, content: path[path.count - 1], rect: bounds, depth: 1, insideCandidate: rootInside)
        return tiles
    }
}

/// Sunburst: rings by depth, angles by size (C8, v2).
struct SunburstView: View {
    let tree: ScanTree
    let root: NodeID
    @Binding var selection: NodeID?
    var highlight: MapHighlight?
    var colors: KindShares?
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
                        var fill = tree.isDirectory(s.id) ? Color.kmWater.opacity(opacity) : Color.kmSurface
                        let group = colors?.group(of: s.id, in: tree)
                        if let kind = group?.color { fill = tree.isDirectory(s.id) ? kind.opacity(max(0.45, opacity * 0.8)) : kind }
                        if let h = highlight {
                            if h.candidates.contains(s.id) { fill = .kmAccent }
                            else if h.isInsideCandidate(s.id, tree: tree) { fill = .kmAccentSoft }
                            else if !h.lit.contains(s.id) { fill = fill.opacity(0.22) }
                        }
                        ctx.fill(p, with: .color(fill))
                        if group == .document, highlight == nil {
                            var c = ctx
                            c.clip(to: p)
                            TreemapView.stripes(p.boundingRect, in: c)
                        }
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
