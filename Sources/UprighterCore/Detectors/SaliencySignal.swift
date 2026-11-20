import Foundation
import Vision

/// Where the subject sits in the frame.
///
/// Photographers put subjects at or above the middle far more often than below it,
/// so the attention-saliency centroid leans upward in upright pictures. This is a
/// genuinely weak cue - centred landscapes and low-angle shots break it - and it is
/// weighted accordingly. It earns its place only as a tie-breaker when nothing
/// stronger fires.
public struct SaliencySignal: OrientationSignal {
    public let name = "subject placement"
    public let blurb = "Whether the salient subject sits above centre (weak tie-breaker)"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        guard let obs = ctx.saliency(), let objects = obs.salientObjects, !objects.isEmpty else {
            return .empty(name, "no salient region", elapsedMS: ms(t0))
        }
        var cx = 0.0, cy = 0.0, wsum = 0.0
        for o in objects {
            let w = Double(o.confidence) * Double(o.boundingBox.width * o.boundingBox.height)
            cx += Double(o.boundingBox.midX) * w
            cy += Double(o.boundingBox.midY) * w
            wsum += w
        }
        guard wsum > 0 else { return .empty(name, "degenerate saliency", elapsedMS: ms(t0)) }
        cx /= wsum; cy /= wsum   // normalised, y-up

        // "How far up the frame does the subject sit" for each candidate turn.
        // Turning clockwise brings the left edge to the top.
        let upness = [cy, 1 - cx, 1 - cy, cx]
        let scores = upness.map { $0 - 0.5 }
        let spread = (scores.max() ?? 0) - (scores.min() ?? 0)
        guard spread > 0.04 else {
            return .empty(name, "subject is centred", elapsedMS: ms(t0))
        }
        let detail = String(format: "subject at (%.2f, %.2f) of frame", cx, cy)
        return .fromScores(source: name,
                           scores: scores,
                           scale: 0.45,
                           confidence: min(0.35, spread),
                           detail: detail,
                           elapsedMS: ms(t0))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
