import CoreGraphics

/// Squarified treemap (Bruls, Huizing, van Wijk 2000).
public enum TreemapLayout {
    /// Lays `sizes` out inside `rect`. Output has the same order as `sizes`; areas are proportional to sizes.
    /// Zero, negative or non-finite sizes get an empty rect at `rect.origin`.
    public static func squarify(sizes: [Double], in rect: CGRect) -> [CGRect] {
        let empty = CGRect(origin: rect.origin, size: .zero)
        var result = [CGRect](repeating: empty, count: sizes.count)
        let bounds = rect.standardized
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return result }
        let items = sizes.indices.filter { sizes[$0].isFinite && sizes[$0] > 0 }.sorted { sizes[$0] != sizes[$1] ? sizes[$0] > sizes[$1] : $0 < $1 }
        let total = items.reduce(0.0) { $0 + sizes[$1] }
        guard total > 0 else { return result }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = items.map { sizes[$0] * scale }

        var x = Double(bounds.minX), y = Double(bounds.minY)
        var w = Double(bounds.width), h = Double(bounds.height)
        var i = 0
        while i < items.count {
            let side = min(w, h)
            guard side > 0 else { break }
            // Grow the row while the worst aspect ratio improves.
            var rowSum = areas[i]
            var j = i + 1
            var worstSoFar = worst(sum: rowSum, maxA: areas[i], minA: areas[i], side: side)
            while j < items.count {
                let candidate = worst(sum: rowSum + areas[j], maxA: areas[i], minA: areas[j], side: side)
                if candidate > worstSoFar { break }
                worstSoFar = candidate
                rowSum += areas[j]
                j += 1
            }
            let isLast = j == items.count
            if w >= h {
                // Column on the left, items stacked top to bottom.
                let colW = isLast ? w : rowSum / h
                var cy = y
                for k in i..<j {
                    let ih = (k == j - 1) ? (y + h - cy) : areas[k] / colW
                    result[items[k]] = CGRect(x: x, y: cy, width: colW, height: max(0, ih))
                    cy += ih
                }
                x += colW; w -= colW
            } else {
                // Row along the top, items left to right.
                let rowH = isLast ? h : rowSum / w
                var cx = x
                for k in i..<j {
                    let iw = (k == j - 1) ? (x + w - cx) : areas[k] / rowH
                    result[items[k]] = CGRect(x: cx, y: y, width: max(0, iw), height: rowH)
                    cx += iw
                }
                y += rowH; h -= rowH
            }
            w = max(0, w); h = max(0, h)
            i = j
        }
        return result
    }

    @inline(__always)
    static func worst(sum: Double, maxA: Double, minA: Double, side: Double) -> Double {
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }
}
