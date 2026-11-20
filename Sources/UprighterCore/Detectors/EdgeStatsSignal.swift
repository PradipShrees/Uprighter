import Foundation

/// Orientation from raw edge statistics - no model at all.
///
/// Built scenes are full of edges that are horizontal or vertical: walls, doors,
/// window frames, tables, poles, the horizon. Those edges stay on a 90 degree grid
/// however the camera is turned, so measuring how far the edge population sits from
/// that grid recovers the TILT very precisely, while saying nothing about which way
/// is up (a 3 degree tilt looks the same at every quarter turn).
///
/// So this contributes two different things:
///   * a precise tilt estimate, modulo 90 degrees - the cue that actually levels
///     architecture and horizons;
///   * a weak preference for the turn that leaves more horizontal than vertical
///     edge energy, which is a real but scene-dependent bias in natural images.
public struct EdgeStatsSignal: OrientationSignal {
    public let name = "edge grid"
    public let blurb = "How far the image's straight edges sit from a horizontal/vertical grid"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        guard let g = ctx.grid(maxEdge: 384) else {
            return .empty(name, "no pixel data", elapsedMS: ms(t0))
        }
        let w = g.width, h = g.height
        guard w >= 16, h >= 16 else { return .empty(name, "image too small", elapsedMS: ms(t0)) }

        var angles: [Double] = []
        var mags: [Double] = []
        var horizEnergy = 0.0, vertEnergy = 0.0

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                @inline(__always) func L(_ dx: Int, _ dy: Int) -> Double {
                    Double(g.luma[i + dy * w + dx])
                }
                // Sobel. Array y grows downward, so negate to get a y-up gradient.
                let gx = (L(1, -1) + 2 * L(1, 0) + L(1, 1)) - (L(-1, -1) + 2 * L(-1, 0) + L(-1, 1))
                let gyDown = (L(-1, 1) + 2 * L(0, 1) + L(1, 1)) - (L(-1, -1) + 2 * L(0, -1) + L(1, -1))
                let gy = -gyDown
                let m = hypot(gx, gy)
                guard m > 0.12 else { continue }
                // The edge runs perpendicular to the gradient.
                let edge = Angle.toDeg(atan2(gy, gx)) + 90
                angles.append(edge)
                mags.append(m)
                if abs(cos(Angle.toRad(edge))) >= abs(sin(Angle.toRad(edge))) {
                    horizEnergy += m
                } else {
                    vertEnergy += m
                }
            }
        }

        guard angles.count >= 60 else {
            return .empty(name, "too few strong edges (\(angles.count))", elapsedMS: ms(t0))
        }

        // Fold onto a 90 degree period: this is where the tilt comes from.
        let folded = Circular.meanMod(angles, period: 90)
        let tilt = Angle.norm180(folded.angle)
        let gridStrength = folded.strength

        // Weak two-fold vote. It cannot tell 0 from 180, only upright-ish from
        // sideways, so the scores come in pairs.
        let total = horizEnergy + vertEnergy
        let hv = total > 0 ? (horizEnergy - vertEnergy) / total : 0
        let scores = [hv, -hv, hv, -hv]

        let ll = scores.map { $0 * 0.55 }
        let detail = String(format: "%d edges, %.0f%% on grid, tilt %+.2f, H/V %+.2f",
                            angles.count, gridStrength * 100, tilt, hv)

        return Evidence(source: name,
                        logLikelihood: ll,
                        // Only trust the tilt when the edges really do form a grid.
                        fineAngleCW: gridStrength > 0.12 ? tilt : nil,
                        finePrecision: gridStrength > 0.12 ? 4.0 * gridStrength : 0,
                        fineIsMod90: true,
                        confidence: min(0.5, abs(hv) * 1.6 + gridStrength * 0.3),
                        detail: detail,
                        elapsedMS: ms(t0))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
