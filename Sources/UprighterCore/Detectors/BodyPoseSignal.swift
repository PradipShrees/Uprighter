import Foundation
import Vision
import CoreGraphics

/// Orientation from human body pose: hips are below shoulders, shoulders below
/// the head. Useful exactly where the face detector struggles - people facing
/// away, too small, or in profile - because the torso is still resolvable.
///
/// Discounted for a reason: people lie down, dive, do handstands and sit on
/// slopes, so a torso axis is a weaker claim about the camera than an eye line is.
public struct BodyPoseSignal: OrientationSignal {
    public let name = "body pose"
    public let blurb = "Hip-to-shoulder axis of detected people"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        let bodies = ctx.bodies()
        guard !bodies.isEmpty else { return .empty(name, "no people", elapsedMS: ms(t0)) }

        let size = ctx.analysisSize
        var angles: [Double] = []
        var weights: [Double] = []

        for body in bodies {
            guard let pts = try? body.recognizedPoints(.all) else { continue }
            func pt(_ k: VNHumanBodyPoseObservation.JointName) -> (CGPoint, Double)? {
                guard let p = pts[k], p.confidence > 0.25 else { return nil }
                return (CGPoint(x: p.location.x * size.width, y: p.location.y * size.height),
                        Double(p.confidence))
            }
            // Prefer the torso axis; fall back to neck-to-nose for head-and-shoulders shots.
            var axis: (from: CGPoint, to: CGPoint, w: Double)?
            if let ls = pt(.leftShoulder), let rs = pt(.rightShoulder),
               let lh = pt(.leftHip), let rh = pt(.rightHip) {
                let sh = CGPoint(x: (ls.0.x + rs.0.x) / 2, y: (ls.0.y + rs.0.y) / 2)
                let hp = CGPoint(x: (lh.0.x + rh.0.x) / 2, y: (lh.0.y + rh.0.y) / 2)
                axis = (hp, sh, (ls.1 + rs.1 + lh.1 + rh.1) / 4)
            } else if let neck = pt(.neck), let nose = pt(.nose) {
                axis = (neck.0, nose.0, (neck.1 + nose.1) / 2 * 0.6)
            }
            guard let a = axis else { continue }
            let dx = a.to.x - a.from.x, dy = a.to.y - a.from.y
            let len = hypot(dx, dy)
            guard len > 4 else { continue }
            // The axis points UP, which is +90 in a y-up space; subtract to get the
            // same "should be 0 when upright" convention the other detectors use.
            angles.append(Angle.norm180(Angle.toDeg(atan2(dy, dx)) - 90))
            weights.append(a.w * Double(len) / Double(max(size.width, size.height)))
        }

        guard !angles.isEmpty, let mean = Circular.mean(angles, weights: weights) else {
            return .empty(name, "\(bodies.count) person(s), pose unclear", elapsedMS: ms(t0))
        }
        let agreement = Circular.resultantLength(angles, weights: weights)
        let detail = String(format: "%d person%@, torso axis %.1f off vertical",
                            angles.count, angles.count == 1 ? "" : "s", mean)
        return .fromAngle(source: name,
                          angleCW: mean,
                          concentration: max(2.6 * agreement, 0.2),
                          confidence: min(0.85, 0.4 + 0.45 * agreement),
                          detail: detail,
                          // A tilted torso is normal, so never level a photo by it.
                          fineUsable: false,
                          elapsedMS: ms(t0))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
