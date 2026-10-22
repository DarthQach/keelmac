import Foundation

public struct SunburstSegment: Sendable, Hashable {
    public let id: NodeID
    /// 0 is the centre disc (the root), 1 the first ring.
    public let depth: Int
    public let startAngle: Double
    public let endAngle: Double
    public init(id: NodeID, depth: Int, startAngle: Double, endAngle: Double) {
        self.id = id; self.depth = depth; self.startAngle = startAngle; self.endAngle = endAngle
    }
    public var span: Double { endAngle - startAngle }
}

public enum SunburstLayout {
    /// Rings by depth with angles proportional to bytes. The root is the depth-0 disc spanning 2π; each child
    /// starts where its previous sibling ended inside its parent's span. Segments narrower than `minAngle`
    /// (radians) are dropped together with their descendants. Order: breadth-first, siblings largest first.
    public static func layout(tree: ScanTree, root: NodeID, maxDepth: Int, minAngle: Double) -> [SunburstSegment] {
        guard root.index < tree.nodeCount else { return [] }
        var out = [SunburstSegment(id: root, depth: 0, startAngle: 0, endAngle: 2 * .pi)]
        var head = 0
        while head < out.count {
            let seg = out[head]; head += 1
            guard seg.depth < maxDepth, tree.isDirectory(seg.id) else { continue }
            let total = Double(tree.bytes(of: seg.id))
            guard total > 0 else { continue }
            var angle = seg.startAngle
            for child in tree.children(of: seg.id) {
                let b = Double(tree.bytes(of: child))
                guard b > 0 else { break } // sorted by size: the rest are empty too
                let span = seg.span * b / total
                if span >= minAngle {
                    out.append(SunburstSegment(id: child, depth: seg.depth + 1, startAngle: angle, endAngle: min(seg.endAngle, angle + span)))
                }
                angle += span
            }
        }
        return out
    }
}
