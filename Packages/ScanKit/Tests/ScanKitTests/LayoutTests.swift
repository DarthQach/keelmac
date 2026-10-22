import CoreGraphics
import Foundation
import Testing
@testable import ScanKit

@Suite("Treemap and sunburst layouts")
struct LayoutTests {
    func randomSizes(_ n: Int, seed: UInt64, range: ClosedRange<Double>) -> [Double] {
        var rng = SplitMix(state: seed)
        return (0..<n).map { _ in Double.random(in: range, using: &rng) }
    }

    func checkInvariants(_ sizes: [Double], _ bounds: CGRect, maxAspect: Double?) {
        let rects = TreemapLayout.squarify(sizes: sizes, in: bounds)
        #expect(rects.count == sizes.count)
        let total = sizes.filter { $0 > 0 }.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        let eps = 1e-6 * area
        for (i, r) in rects.enumerated() {
            if sizes[i] <= 0 {
                #expect(r.width == 0 && r.height == 0)
                continue
            }
            // Area proportional to size.
            let expected = sizes[i] / total * area
            #expect(abs(Double(r.width * r.height) - expected) <= max(eps, expected * 1e-6))
            // Inside bounds.
            #expect(r.minX >= bounds.minX - 1e-6 && r.minY >= bounds.minY - 1e-6)
            #expect(r.maxX <= bounds.maxX + 1e-6 && r.maxY <= bounds.maxY + 1e-6)
            if let maxAspect {
                let aspect = Double(max(r.width / r.height, r.height / r.width))
                #expect(aspect <= maxAspect, "rect \(i) aspect \(aspect)")
            }
        }
        // No overlaps.
        for i in rects.indices where sizes[i] > 0 {
            for j in rects.indices where j > i && sizes[j] > 0 {
                let x = rects[i].intersection(rects[j])
                #expect(x.isNull || Double(x.width * x.height) <= eps, "rects \(i) and \(j) overlap")
            }
        }
        // Union covers the bounds (areas sum to the full rect).
        let sum = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(sum - area) <= 1e-6 * area)
    }

    @Test func treemapInvariantsRandom() {
        for seed in UInt64(1)...20 {
            checkInvariants(randomSizes(60, seed: seed, range: 1...10), CGRect(x: 10, y: 20, width: 800, height: 600), maxAspect: 6)
        }
    }

    @Test func treemapSkewedSizes() {
        var sizes = randomSizes(200, seed: 99, range: 0.001...1)
        sizes[0] = 10_000
        checkInvariants(sizes, CGRect(x: 0, y: 0, width: 1200, height: 300), maxAspect: nil)
    }

    @Test func treemapEqualSizesAreSquareish() {
        checkInvariants(Array(repeating: 1, count: 16), CGRect(x: 0, y: 0, width: 400, height: 400), maxAspect: 1.5)
    }

    @Test func treemapZeroSizesAndOrder() {
        let sizes: [Double] = [0, 5, 0, 1, 3]
        let rects = TreemapLayout.squarify(sizes: sizes, in: CGRect(x: 0, y: 0, width: 90, height: 10))
        #expect(rects[0].isEmpty && rects[2].isEmpty)
        #expect(abs(Double(rects[1].width * rects[1].height) - 500) < 1e-6)
        #expect(abs(Double(rects[3].width * rects[3].height) - 100) < 1e-6)
        #expect(abs(Double(rects[4].width * rects[4].height) - 300) < 1e-6)
        #expect(TreemapLayout.squarify(sizes: [], in: CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty)
        #expect(TreemapLayout.squarify(sizes: [0, 0], in: CGRect(x: 0, y: 0, width: 1, height: 1)).allSatisfy { $0.isEmpty })
        #expect(TreemapLayout.squarify(sizes: [1], in: .zero).allSatisfy { $0.isEmpty })
        let one = TreemapLayout.squarify(sizes: [7], in: CGRect(x: 3, y: 4, width: 50, height: 20))
        #expect(one == [CGRect(x: 3, y: 4, width: 50, height: 20)])
    }

    func sunburstTree() -> ScanTree {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        return makeTree([
            ("a", true, 600, 1, d), ("a/x", true, 300, 1, d), ("a/y", true, 100, 1, d), ("a/y/z", true, 50, 1, d),
            ("b", true, 300, 1, d), ("tiny", true, 1, 1, d), ("empty", true, 0, 0, d), ("file.bin", false, 99, 1, d),
        ])
    }

    @Test func sunburstInvariants() {
        let t = sunburstTree()
        let segs = SunburstLayout.layout(tree: t, root: t.root, maxDepth: 3, minAngle: 0.01)
        let byID = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0) })
        let root = try! #require(byID[t.root])
        #expect(root.depth == 0 && root.startAngle == 0 && abs(root.endAngle - 2 * .pi) < 1e-12)
        for s in segs where s.id != t.root {
            let parent = try! #require(byID[t.parent(of: s.id)!])
            #expect(s.depth == parent.depth + 1)
            #expect(s.depth <= 3)
            #expect(s.startAngle >= parent.startAngle - 1e-12 && s.endAngle <= parent.endAngle + 1e-12)
            // Angle proportional to bytes.
            let ratio = Double(t.bytes(of: s.id)) / Double(t.bytes(of: parent.id))
            #expect(abs(s.span - parent.span * ratio) < 1e-9)
            #expect(s.span >= 0.01)
        }
        // Siblings do not overlap and stay inside the parent.
        for p in segs {
            let kids = segs.filter { $0.id != t.root && t.parent(of: $0.id) == p.id }.sorted { $0.startAngle < $1.startAngle }
            #expect(kids.reduce(0) { $0 + $1.span } <= p.span + 1e-9)
            for (k1, k2) in zip(kids, kids.dropFirst()) { #expect(k1.endAngle <= k2.startAngle + 1e-12) }
        }
        let names = Set(segs.map { t.name(of: $0.id) })
        #expect(names.contains("file.bin"))
        #expect(!names.contains("tiny"))   // 1/1450 of 2π < 0.01 rad
        #expect(!names.contains("empty"))  // zero bytes
        #expect(names.contains("z"))       // depth 3
    }

    @Test func sunburstMaxDepthAndSubtreeRoot() {
        let t = sunburstTree()
        #expect(SunburstLayout.layout(tree: t, root: t.root, maxDepth: 1, minAngle: 0).allSatisfy { $0.depth <= 1 })
        let a = t.lookup(path: "/R/a")!
        let segs = SunburstLayout.layout(tree: t, root: a, maxDepth: 5, minAngle: 0)
        #expect(segs.first?.id == a)
        #expect(Set(segs.map { t.name(of: $0.id) }) == ["a", "x", "y", "z"])
        #expect(SunburstLayout.layout(tree: t, root: NodeID(raw: 9999), maxDepth: 2, minAngle: 0).isEmpty)
    }
}
