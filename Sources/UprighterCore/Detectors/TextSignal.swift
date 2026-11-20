import Foundation
import Vision
import CoreGraphics

/// Orientation from text baselines - the strongest cue available when a picture
/// contains writing.
///
/// Two measured facts shape this detector:
///
///  1. The NUMBER of characters Vision reads is useless as a cue on its own: it
///     recognises text at any rotation, returning ~4850 characters at all four
///     turns of one screenshot. What is informative is the quadrilateral per line,
///     whose top edge runs along the baseline. That tracked true rotation to within
///     0.2 degrees.
///
///  2. But the quad's 0-versus-180 decision is NOT stable. Vision decides
///     internally whether it is reading upside-down text, and on borderline input
///     it flips: two renderings of the same 180-degree-rotated screenshot, differing
///     only in downscale filtering, gave "3368 characters at 180" and "986
///     characters at 0". The axis was right both times; the flip was not.
///
/// So the baseline angle is trusted for the AXIS, and the flip is settled by
/// re-reading the picture the other way up and comparing how much text comes back -
/// Vision reads far more when it has the flip right. When the two readings are
/// close, that uncertainty is carried through as a two-component mixture instead of
/// being hidden behind a coin-flip.
public struct TextSignal: OrientationSignal {
    public let name = "text lines"
    public let blurb = "Direction of recognised text baselines, verified by re-reading upside down"

    /// When false, trust Vision's first reading instead of re-reading the picture
    /// the other way up. Roughly halves the time and measurably costs accuracy on
    /// 180-degree cases, so it is off by default.
    public var verifyFlip: Bool

    public init(verifyFlip: Bool = true) { self.verifyFlip = verifyFlip }

    struct Reading {
        var angle: Double      // baseline direction within this frame
        var agreement: Double  // how much the lines agree with each other
        var chars: Int
        var score: Double      // characters weighted by confidence: "how readable"
        var lines: Int
    }

    private func read(_ ctx: ImageContext, _ turn: QuarterTurn) -> Reading? {
        let lines = ctx.textLines(turn)
        guard !lines.isEmpty else { return nil }
        let size = ctx.analysisSize(turn)
        let w = Double(size.width), h = Double(size.height)
        var angles: [Double] = [], weights: [Double] = []
        var chars = 0, score = 0.0
        for line in lines {
            // Normalised coordinates squash the aspect ratio; scale to pixels first.
            let dx = Double(line.topRight.x - line.topLeft.x) * w
            let dy = Double(line.topRight.y - line.topLeft.y) * h
            let len = hypot(dx, dy)
            guard len > 6 else { continue }
            let cand = line.topCandidates(1).first
            let n = cand?.string.count ?? 0
            let conf = Double(cand?.confidence ?? line.confidence)
            chars += n
            score += Double(n) * max(conf, 0.05)
            angles.append(Angle.toDeg(atan2(dy, dx)))
            weights.append(len * max(conf, 0.1))
        }
        guard !angles.isEmpty, let mean = Circular.mean(angles, weights: weights) else { return nil }
        return Reading(angle: mean,
                       agreement: Circular.resultantLength(angles, weights: weights),
                       chars: chars, score: score, lines: angles.count)
    }

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        let t0 = Date()
        guard let first = read(ctx, .none) else {
            return .empty(name, "no text", elapsedMS: ms(t0))
        }

        // Substance gate: a handful of short fragments is exactly what a
        // half-failed read produces, and must not become a confident vote.
        let substance = min(1.0, Double(first.lines) / 12.0) * min(1.0, Double(first.chars) / 120.0)
        guard substance > 0.08, first.agreement > 0.45 else {
            return .empty(name,
                          "only \(first.lines) line(s)/\(first.chars) chars - not enough to trust",
                          elapsedMS: ms(t0))
        }

        // The baseline angle fixes the axis. Snap to it, then test both flips.
        let candidate = QuarterTurn.nearest(toCW: first.angle)
        let opposite = QuarterTurn(rawValue: Int(Angle.norm360(candidate.degreesCW + 180))) ?? .cw180

        let a = candidate == .none ? first : (verifyFlip ? read(ctx, candidate) : first)
        let b = verifyFlip ? (opposite == .none ? first : read(ctx, opposite)) : nil

        // Angle within a turned frame adds to that turn: correcting by `turn` and
        // then by the leftover angle is the total correction.
        func total(_ turn: QuarterTurn, _ r: Reading?) -> (angle: Double, score: Double)? {
            guard let r else { return nil }
            return (Angle.norm180(turn.degreesCW + r.angle), r.score)
        }
        let candAngle = total(candidate, a)
        let oppAngle = total(opposite, b)

        var ll = [Double](repeating: 0, count: 4)
        let concentration = max(0.2, 9.0 * first.agreement * (0.35 + 0.65 * substance))
        var chosenAngle = Angle.norm180(first.angle)
        var flipNote = ""

        switch (candAngle, oppAngle) {
        case let (cand?, opp?):
            // Weight the two flips by how readable each one was.
            let totalScore = cand.score + opp.score
            let pCand = totalScore > 0 ? cand.score / totalScore : 0.5
            let pOpp = 1 - pCand
            ll = QuarterTurn.allCases.map { turn in
                let eC = concentration * cos(Angle.toRad(cand.angle - turn.degreesCW))
                let eO = concentration * cos(Angle.toRad(opp.angle - turn.degreesCW))
                // log(p1*exp(e1) + p2*exp(e2)), computed stably.
                let m = max(eC, eO)
                return m + log(max(pCand, 1e-9) * exp(eC - m) + max(pOpp, 1e-9) * exp(eO - m))
            }
            chosenAngle = pCand >= pOpp ? cand.angle : opp.angle
            flipNote = String(format: ", flip %.0f%% sure (%.0f vs %.0f readable)",
                              max(pCand, pOpp) * 100, cand.score, opp.score)
        case let (cand?, nil):
            ll = QuarterTurn.allCases.map {
                concentration * cos(Angle.toRad(cand.angle - $0.degreesCW))
            }
            chosenAngle = cand.angle
            flipNote = ", upside down read nothing"
        default:
            ll = QuarterTurn.allCases.map {
                concentration * cos(Angle.toRad(Angle.norm180(first.angle) - $0.degreesCW))
            }
        }

        let confidence = min(1.0, first.agreement * (0.4 + 0.6 * substance))
        let detail = String(format: "%d lines, %d chars, baseline %.1f%@",
                            first.lines, first.chars, first.angle, flipNote)

        return Evidence(source: name,
                        logLikelihood: ll,
                        fineAngleCW: chosenAngle,
                        finePrecision: concentration * confidence,
                        confidence: confidence,
                        detail: detail,
                        elapsedMS: ms(t0))
    }

    private func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
}
