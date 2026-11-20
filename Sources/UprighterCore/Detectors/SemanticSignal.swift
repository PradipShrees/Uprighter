import Foundation
import Vision

/// "Which way up does this look most like a photograph?"
///
/// Vision's scene classifier was trained on upright photos, so its confidence
/// drops when the content is turned. Summing the top few confidences over the four
/// turns turns that bias into an orientation cue - a general-purpose stand-in for
/// training a dedicated rotation network, and the main fallback for pictures with
/// no faces, no text and no horizon.
///
/// Measured on a portrait: 3.30 upright, 2.87 at 90, 2.70 at 270, 2.25 upside down.
/// Correct ordering, but a modest margin, so it is weighted as a hint and it only
/// resolves quarter turns - never fine tilt.
public struct SemanticSignal: OrientationSignal {
    public let name = "scene model"
    public let blurb = "Scene-classifier confidence compared across the four turns"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        var scores: [Double] = []
        for turn in QuarterTurn.allCases {
            let cls = ctx.classifications(turn)
                .filter { $0.confidence > 0.02 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
            scores.append(cls.reduce(0.0) { $0 + Double($1.confidence) })
        }
        guard let best = scores.max(), best > 0.05 else {
            return .empty(name, "classifier had no opinion", elapsedMS: ms(t0))
        }
        let sorted = scores.sorted(by: >)
        let margin = sorted[0] - sorted[1]
        // A clear winner is worth something; a photographic finish is not.
        let relative = best > 0 ? margin / best : 0
        let confidence = min(0.75, relative * 2.2)
        let topName = ctx.classifications(QuarterTurn.allCases[scores.firstIndex(of: best) ?? 0])
            .max(by: { $0.confidence < $1.confidence })?.identifier ?? "?"
        let detail = String(format: "scores %.2f/%.2f/%.2f/%.2f, best looks like \"%@\"",
                            scores[0], scores[1], scores[2], scores[3], topName)
        return .fromScores(source: name,
                           scores: scores,
                           scale: 1.6,
                           confidence: confidence,
                           detail: detail,
                           elapsedMS: ms(t0))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
