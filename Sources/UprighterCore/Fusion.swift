import Foundation

/// How sure we are, in words.
public enum Verdict: String, Sendable {
    case confident      // act on it
    case likely         // probably right, worth a glance
    case uncertain      // ask a human
    case noEvidence     // nothing fired at all
}

public struct OrientationResult: Sendable {
    /// The quarter turn to apply to the stored pixels.
    public var turn: QuarterTurn
    /// Probability of each quarter turn, in `QuarterTurn.allCases` order.
    public var posterior: [Double]
    /// Probability of the winner.
    public var confidence: Double
    /// Winner minus runner-up. The honest measure of "was this close?".
    public var margin: Double
    /// Residual tilt in degrees after the quarter turn, when measurable.
    public var fineTiltCW: Double?
    public var fineTiltConfidence: Double
    public var verdict: Verdict
    public var evidence: [Evidence]
    public var totalMS: Double

    /// Set when the file itself is damaged (truncated), independently of orientation.
    public var damage: String?

    /// The turn the file's own orientation tag already applies, if it has one.
    /// A viewer that honours the tag is already showing the photo turned this way.
    public var existingTagTurn: QuarterTurn?

    /// What is still wrong with how the photo LOOKS right now.
    ///
    /// `turn` describes the stored pixels, which is what must be written. But if
    /// the file's tag already expresses that turn, every viewer that honours it
    /// shows the photo upright and there is nothing for the user to fix. This is
    /// the difference, and it is what the interface should report.
    public var displayTurn: QuarterTurn {
        let tag = existingTagTurn?.degreesCW ?? 0
        return QuarterTurn(rawValue: Int(Angle.norm360(turn.degreesCW - tag))) ?? .none
    }

    /// True when the photo already appears the right way up to a viewer that
    /// honours orientation tags, whatever the stored pixels look like.
    public var looksUprightAlready: Bool { displayTurn == .none }

    /// Everything that actually had something to say.
    public var contributing: [Evidence] { evidence.filter { $0.confidence > 0.02 } }

    /// Whether anything needs doing from the user's point of view.
    public var needsRotation: Bool { displayTurn != .none }

    /// Whether the stored pixels themselves are sideways (true even when a tag
    /// already compensates). Only relevant when normalising files.
    public var storedPixelsNeedTurn: Bool { turn != .none }

    public var summary: String {
        switch verdict {
        case .noEvidence: return "no usable cue found"
        case .uncertain:  return "unsure - best guess \(displayTurn.label)"
        case .likely:     return "\(displayTurn.label) (likely)"
        case .confident:  return displayTurn.label
        }
    }
}

public enum Fusion {

    /// Per-detector trust, applied on top of each detector's own per-image strength.
    /// These are the knobs worth tuning; everything else is measurement.
    public static let defaultWeights: [String: Double] = [
        "text lines": 1.00,          // measured sub-degree, self-disambiguating
        "face/eyes": 1.00,           // measured ~1 degree, resolves full 360
        "EXIF tag": 0.90,            // usually right when present, but it is a claim
        "body pose": 0.65,           // real cue, but people lie down
        "scene model": 0.60,         // correct ordering, modest margin
        "sky/ground": 0.50,          // strong on landscapes, silent elsewhere
        "edge grid": 0.45,           // mostly a levelling cue
        "subject placement": 0.22,   // tie-breaker only
        "horizon": 0.0,              // contributes no quarter-turn vote by design
    ]

    public static func softmax(_ x: [Double]) -> [Double] {
        guard let m = x.max() else { return [] }
        let e = x.map { exp($0 - m) }
        let s = e.reduce(0, +)
        guard s > 0 else { return Array(repeating: 1.0 / Double(x.count), count: x.count) }
        return e.map { $0 / s }
    }

    /// Combine every detector's evidence into one answer.
    public static func combine(_ evidence: [Evidence],
                               weights: [String: Double] = defaultWeights,
                               maxFineTilt: Double = 20) -> OrientationResult {

        var totals = [Double](repeating: 0, count: 4)
        for e in evidence {
            guard e.confidence > 0.02, e.logLikelihood.count == 4 else { continue }
            let w = weights[e.source] ?? 0.5
            guard w > 0 else { continue }
            for i in 0..<4 { totals[i] += w * e.logLikelihood[i] }
        }

        let posterior = softmax(totals)
        let bestIdx = posterior.indices.max(by: { posterior[$0] < posterior[$1] }) ?? 0
        let turn = QuarterTurn.allCases[bestIdx]
        let sorted = posterior.sorted(by: >)
        let margin = sorted.count > 1 ? sorted[0] - sorted[1] : 0
        let anyEvidence = evidence.contains { $0.confidence > 0.02 && $0.logLikelihood.contains { $0 != 0 } }

        // Fine tilt: residual left over once the quarter turn is taken out.
        var residuals: [Double] = []
        var residualWeights: [Double] = []
        for e in evidence {
            guard let fine = e.fineAngleCW, e.finePrecision > 0, e.confidence > 0.02 else { continue }
            let r = e.fineIsMod90 ? Angle.norm180(fine) : Angle.norm180(fine - turn.degreesCW)
            guard abs(r) <= maxFineTilt else { continue }
            residuals.append(r)
            residualWeights.append(e.finePrecision)
        }
        var fineTilt: Double?
        var fineConf = 0.0
        if !residuals.isEmpty, let m = Circular.mean(residuals, weights: residualWeights) {
            let agree = Circular.resultantLength(residuals, weights: residualWeights)
            // One lone cue is enough only if it is a precise one; two that agree is better.
            let strength = residualWeights.reduce(0, +)
            if agree > 0.6 && strength > 1.5 && abs(m) > 0.25 {
                fineTilt = Angle.norm180(m)
                fineConf = min(1.0, agree * min(1.0, strength / 6.0))
            }
        }

        let verdict: Verdict
        if !anyEvidence { verdict = .noEvidence }
        else if margin > 0.55 { verdict = .confident }
        else if margin > 0.22 { verdict = .likely }
        else { verdict = .uncertain }

        return OrientationResult(turn: verdict == .noEvidence ? .none : turn,
                                 posterior: posterior,
                                 confidence: posterior[bestIdx],
                                 margin: margin,
                                 fineTiltCW: fineTilt,
                                 fineTiltConfidence: fineConf,
                                 verdict: verdict,
                                 evidence: evidence,
                                 totalMS: evidence.reduce(0) { $0 + $1.elapsedMS })
    }
}
