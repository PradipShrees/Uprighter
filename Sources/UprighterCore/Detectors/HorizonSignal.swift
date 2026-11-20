import Foundation
import Vision

/// Apple's dedicated horizon detector.
///
/// It reports the tilt of a detected horizon, which is excellent for levelling but
/// says nothing about which way is up - a horizon looks like a horizon upside down.
/// So this is a fine-tilt cue only, with no vote on the quarter turn. It also
/// declines to fire on most non-landscape pictures, which is why it cannot be the
/// backbone of the system.
public struct HorizonSignal: OrientationSignal {
    public let name = "horizon"
    public let blurb = "Tilt of a detected horizon line (levelling only)"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        guard let obs = ctx.horizon() else {
            return .empty(name, "no horizon found", elapsedMS: ms(t0))
        }
        let deg = Angle.toDeg(Double(obs.angle))
        // Vision reports the horizon's own inclination; levelling means undoing it.
        let residual = Angle.norm180(deg)
        guard abs(residual) <= 45 else {
            return .empty(name, String(format: "implausible angle %.1f", deg), elapsedMS: ms(t0))
        }
        return .fineOnlyMod90(source: name,
                              residualCW: residual,
                              precision: 5.0,
                              confidence: 0.6,
                              detail: String(format: "horizon tilted %+.2f", residual),
                              elapsedMS: ms(t0))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
