import Foundation

/// Orientation from the oldest cue there is: the sky is up.
///
/// Compares the four border strips. Sky tends to be brighter, bluer and smoother;
/// ground tends to be darker, warmer and far more textured. No model, no network -
/// just band statistics - which makes it the cue that still works on landscapes
/// with no faces, no text and no detectable horizon. It is a prior, not a
/// measurement, so it is weighted modestly and never used for fine levelling.
public struct SkyGroundSignal: OrientationSignal {
    public let name = "sky/ground"
    public let blurb = "Brightness, colour and texture difference between opposite edges"

    public init() {}

    struct Band { var luma = 0.0; var blueness = 0.0; var texture = 0.0 }

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        guard let g = ctx.grid() else { return .empty(name, "no pixel data", elapsedMS: ms(t0)) }
        let w = g.width, h = g.height
        guard w >= 8, h >= 8 else { return .empty(name, "image too small", elapsedMS: ms(t0)) }

        let bandH = max(2, h / 4), bandW = max(2, w / 4)
        let top = stats(g, xs: 0..<w, ys: 0..<bandH)
        let bottom = stats(g, xs: 0..<w, ys: (h - bandH)..<h)
        let left = stats(g, xs: 0..<bandW, ys: 0..<h)
        let right = stats(g, xs: (w - bandW)..<w, ys: 0..<h)

        // Which strip ends up on top after each clockwise turn. Turning the image
        // clockwise swings its LEFT edge upward, hence cw90 -> left.
        let pairs: [(up: Band, down: Band)] = [
            (top, bottom),      // none
            (left, right),      // cw90
            (bottom, top),      // cw180
            (right, left),      // cw270
        ]

        let scores = pairs.map { p in
            1.0 * (p.up.luma - p.down.luma)
          + 1.5 * (p.up.blueness - p.down.blueness)
          + 0.8 * (p.down.texture - p.up.texture)
        }

        let spread = (scores.max() ?? 0) - (scores.min() ?? 0)
        guard spread > 0.02 else {
            return .empty(name, "edges look alike (no sky/ground split)", elapsedMS: ms(t0))
        }
        let confidence = min(0.7, spread * 2.0)
        let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
        let detail = String(format: "%@ edge looks most like sky (margin %.3f)",
                            ["top", "left", "bottom", "right"][bestIdx], spread)
        return .fromScores(source: name,
                           scores: scores,
                           scale: 1.3,
                           confidence: confidence,
                           detail: detail,
                           elapsedMS: ms(t0))
    }

    private func stats(_ g: PixelGrid, xs: Range<Int>, ys: Range<Int>) -> Band {
        var b = Band()
        var n = 0.0
        var lumas: [Float] = []
        lumas.reserveCapacity(xs.count * ys.count)
        for y in ys {
            for x in xs {
                let i = y * g.width + x
                b.luma += Double(g.luma[i])
                // Sky is blue-dominant; soil, rock, grass and skin are not.
                b.blueness += Double(g.blue[i] - g.red[i])
                lumas.append(g.luma[i])
                n += 1
            }
        }
        guard n > 0 else { return b }
        b.luma /= n
        b.blueness /= n
        // Texture as local gradient energy: sky is smooth, ground is busy.
        var tex = 0.0
        var m = 0.0
        for y in ys.dropLast() {
            for x in xs.dropLast() {
                let i = y * g.width + x
                let dx = Double(g.luma[i + 1] - g.luma[i])
                let dy = Double(g.luma[i + g.width] - g.luma[i])
                tex += hypot(dx, dy)
                m += 1
            }
        }
        b.texture = m > 0 ? tex / m : 0
        return b
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
