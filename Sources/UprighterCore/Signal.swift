import Foundation

/// What one detector concluded about an image.
///
/// Every detector speaks the same language: a score for each of the four quarter
/// turns, plus (optionally) a precise continuous angle for fine levelling.
public struct Evidence: Sendable {
    /// Short detector name, shown in the UI.
    public var source: String
    /// Log-likelihood for each quarter turn, indexed by `QuarterTurn.allCases`.
    /// Only differences matter; an all-zero vector means "no opinion".
    public var logLikelihood: [Double]
    /// A precise clockwise-rotation estimate, when the detector can give one.
    public var fineAngleCW: Double?
    /// Weight for this detector's `fineAngleCW` when averaging fine angles.
    public var finePrecision: Double
    /// True when `fineAngleCW` is only meaningful modulo 90 degrees - it pins down
    /// the tilt but not which way is up. Edge statistics and the horizon detector
    /// are like this: fusion adds the chosen quarter turn back on.
    public var fineIsMod90: Bool
    /// Self-assessed reliability on THIS image, 0...1. Zero means "I found nothing".
    public var confidence: Double
    /// One line for the UI explaining what was found.
    public var detail: String
    /// Milliseconds spent.
    public var elapsedMS: Double

    public init(source: String,
                logLikelihood: [Double] = [0, 0, 0, 0],
                fineAngleCW: Double? = nil,
                finePrecision: Double = 0,
                fineIsMod90: Bool = false,
                confidence: Double = 0,
                detail: String = "",
                elapsedMS: Double = 0) {
        self.source = source
        self.logLikelihood = logLikelihood
        self.fineAngleCW = fineAngleCW
        self.finePrecision = finePrecision
        self.fineIsMod90 = fineIsMod90
        self.confidence = confidence
        self.detail = detail
        self.elapsedMS = elapsedMS
    }

    public static func empty(_ source: String, _ detail: String = "nothing found", elapsedMS: Double = 0) -> Evidence {
        Evidence(source: source, confidence: 0, detail: detail, elapsedMS: elapsedMS)
    }

    /// Build evidence from a continuous angle estimate.
    ///
    /// `concentration` is a von Mises kappa: how sharply the angle pins down the
    /// answer. Large (6+) for geometric measurements like a text baseline, small
    /// (<1) for soft statistical hints.
    public static func fromAngle(source: String,
                                 angleCW: Double,
                                 concentration: Double,
                                 confidence: Double,
                                 detail: String,
                                 fineUsable: Bool = true,
                                 elapsedMS: Double = 0) -> Evidence {
        let ll = QuarterTurn.allCases.map { turn in
            concentration * cos(Angle.toRad(angleCW - turn.degreesCW))
        }
        return Evidence(source: source,
                        logLikelihood: ll,
                        fineAngleCW: fineUsable ? angleCW : nil,
                        finePrecision: fineUsable ? concentration * confidence : 0,
                        confidence: confidence,
                        detail: detail,
                        elapsedMS: elapsedMS)
    }

    /// Build evidence that pins down tilt but not which way is up.
    public static func fineOnlyMod90(source: String,
                                     residualCW: Double,
                                     precision: Double,
                                     confidence: Double,
                                     detail: String,
                                     elapsedMS: Double = 0) -> Evidence {
        Evidence(source: source,
                 logLikelihood: [0, 0, 0, 0],
                 fineAngleCW: Angle.norm180(residualCW),
                 finePrecision: precision,
                 fineIsMod90: true,
                 confidence: confidence,
                 detail: detail,
                 elapsedMS: elapsedMS)
    }

    /// Build evidence from four raw per-turn scores (higher = more likely upright
    /// after that turn). Scores are centred and scaled, so only their spread matters.
    public static func fromScores(source: String,
                                  scores: [Double],
                                  scale: Double,
                                  confidence: Double,
                                  detail: String,
                                  elapsedMS: Double = 0) -> Evidence {
        guard scores.count == 4 else { return .empty(source, "bad score vector") }
        let mean = scores.reduce(0, +) / 4
        let centred = scores.map { $0 - mean }
        let spread = centred.map { abs($0) }.max() ?? 0
        guard spread > 1e-9 else { return .empty(source, detail) }
        // Normalise so the strongest deviation is `scale`, keeping relative shape.
        let ll = centred.map { $0 / spread * scale }
        return Evidence(source: source,
                        logLikelihood: ll,
                        fineAngleCW: nil,
                        finePrecision: 0,
                        confidence: confidence,
                        detail: detail,
                        elapsedMS: elapsedMS)
    }

    /// The turn this detector likes best, ignoring everything else.
    public var ownBest: QuarterTurn {
        guard confidence > 0, let i = logLikelihood.indices.max(by: { logLikelihood[$0] < logLikelihood[$1] })
        else { return .none }
        return QuarterTurn.allCases[i]
    }

    /// Posterior over turns from this detector alone, for the UI's bars.
    public var ownPosterior: [Double] { Fusion.softmax(logLikelihood) }
}

/// A detector: looks at a prepared image and reports what it sees.
public protocol OrientationSignal: Sendable {
    /// Stable short name, also the key used for its fusion weight.
    var name: String { get }
    /// Longer description for `--explain` and UI tooltips.
    var blurb: String { get }
    func evaluate(_ ctx: ImageContext) throws -> Evidence
}
