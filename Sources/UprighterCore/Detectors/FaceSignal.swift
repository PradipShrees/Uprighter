import Foundation
import Vision
import CoreGraphics

/// Orientation from faces: the line through the eyes, cross-checked against the
/// eyes-to-mouth direction.
///
/// Two facts about Vision make this work well:
///   * its face detector finds faces at ANY in-plane rotation, so we never need
///     to re-run it on rotated copies;
///   * it labels left vs right eye from the viewer's side even upside down, so
///     the eye line resolves a full 360 degrees on its own, not just 180.
///
/// `VNFaceObservation.roll` is also read, but only as a sanity check: measurement
/// showed it is quantised to 30 degree steps, while the landmarks are continuous
/// and accurate to about a degree.
public struct FaceSignal: OrientationSignal {
    public let name = "face/eyes"
    public let blurb = "Angle of the eye line, confirmed by the eyes-to-mouth direction"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        let faces = ctx.faces()
        let size = ctx.analysisSize
        guard !faces.isEmpty else {
            return .empty(name, "no faces", elapsedMS: ms(t0))
        }

        var angles: [Double] = []
        var weights: [Double] = []
        var mouthAgreements: [Bool] = []
        var usable = 0

        for f in faces {
            guard let lm = f.landmarks else { continue }
            guard let leftEye = lm.leftEye, let rightEye = lm.rightEye else { continue }
            let l = centroid(leftEye, size)
            let r = centroid(rightEye, size)
            let dx = r.x - l.x, dy = r.y - l.y
            let span = hypot(dx, dy)
            guard span > 2 else { continue }

            // Vision's coordinates are y-up, so this is CCW-positive: exactly the
            // "feature angle" the rest of the program expects.
            let eyeAngle = Angle.toDeg(atan2(dy, dx))

            // Cross-check with the mouth, which must sit BELOW the eyes.
            var agrees = true
            if let lips = lm.outerLips ?? lm.innerLips {
                let m = centroid(lips, size)
                let eyeMid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
                let mouthAngle = Angle.toDeg(atan2(m.y - eyeMid.y, m.x - eyeMid.x))
                // Down is -90 in a y-up space, so this should also land near the eye angle.
                let implied = mouthAngle + 90
                agrees = Angle.delta(implied, eyeAngle) < 45
            }
            mouthAgreements.append(agrees)

            // Bigger, more confident faces carry more weight; a face whose mouth
            // contradicts its eyes is kept but heavily discounted.
            let area = Double(f.boundingBox.width * f.boundingBox.height)
            var w = sqrt(max(area, 1e-6)) * Double(max(f.confidence, 0.1))
            if !agrees { w *= 0.25 }
            angles.append(eyeAngle)
            weights.append(w)
            usable += 1
        }

        guard usable > 0, let mean = Circular.mean(angles, weights: weights) else {
            return .empty(name, "\(faces.count) face(s) but no usable landmarks", elapsedMS: ms(t0))
        }

        let agreement = Circular.resultantLength(angles, weights: weights)
        let agreeingMouths = mouthAgreements.filter { $0 }.count

        // Faces are a strong, precise cue. Concentration scales with how much the
        // faces agree and whether the mouth confirms the eye line.
        let mouthFactor = usable > 0 ? 0.5 + 0.5 * Double(agreeingMouths) / Double(usable) : 0.5
        let concentration = 7.0 * agreement * mouthFactor
        let confidence = min(1.0, 0.55 + 0.45 * agreement) * mouthFactor

        // Largest face's coarse roll, purely informational.
        let rollNote: String
        if let biggest = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
           let roll = biggest.roll {
            rollNote = String(format: ", roll ~%.0f", Double(truncating: roll) * 180 / .pi)
        } else { rollNote = "" }

        let detail = String(format: "%d face%@, eye line %.1f%@%@",
                            usable, usable == 1 ? "" : "s", mean, rollNote,
                            agreeingMouths < usable ? ", mouth disagrees" : "")

        return .fromAngle(source: name,
                          angleCW: mean,
                          concentration: max(concentration, 0.3),
                          confidence: confidence,
                          detail: detail,
                          // Deliberately not used for levelling. People tilt their
                          // heads constantly, so straightening a photo until the
                          // eyes are level would tilt the whole scene instead. The
                          // eye line decides the quarter turn; the camera-based cues
                          // (edges, horizon, text) decide the fine angle.
                          fineUsable: false,
                          elapsedMS: ms(t0))
    }

    private func centroid(_ region: VNFaceLandmarkRegion2D, _ size: CGSize) -> CGPoint {
        let pts = region.pointsInImage(imageSize: size)
        guard !pts.isEmpty else { return .zero }
        let sx = pts.reduce(0.0) { $0 + Double($1.x) }
        let sy = pts.reduce(0.0) { $0 + Double($1.y) }
        return CGPoint(x: sx / Double(pts.count), y: sy / Double(pts.count))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
