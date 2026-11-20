import Foundation
import CoreGraphics
import CoreImage

/// The pipeline: run every detector over an image, fuse their evidence, and
/// optionally write the corrected file.
public struct Uprighter: Sendable {

    /// Every detector, in the order they are reported.
    public static func allDetectors(fastText: Bool = false) -> [OrientationSignal] {
        [
            ExifSignal(),
            FaceSignal(),
            TextSignal(verifyFlip: !fastText),
            BodyPoseSignal(),
            HorizonSignal(),
            SemanticSignal(),
            SkyGroundSignal(),
            EdgeStatsSignal(),
            SaliencySignal(),
        ]
    }

    public var detectors: [OrientationSignal]
    public var weights: [String: Double]
    public var maxAnalysisEdge: Int
    public var thorough: Bool
    /// Cap on how much fine levelling will ever be applied.
    public var maxFineTilt: Double

    public init(detectors: [OrientationSignal] = Uprighter.allDetectors(),
                weights: [String: Double] = Fusion.defaultWeights,
                maxAnalysisEdge: Int = 1400,
                thorough: Bool = false,
                maxFineTilt: Double = 20) {
        self.detectors = detectors
        self.weights = weights
        self.maxAnalysisEdge = maxAnalysisEdge
        self.thorough = thorough
        self.maxFineTilt = maxFineTilt
    }

    // MARK: - Analysis

    public func analyze(_ ctx: ImageContext, refineTilt: Bool = false) -> OrientationResult {
        var evidence: [Evidence] = []
        for d in detectors {
            let t0 = Date()
            do {
                evidence.append(try d.evaluate(ctx))
            } catch {
                evidence.append(.empty(d.name, "failed: \(error.localizedDescription)",
                                       elapsedMS: Date().timeIntervalSince(t0) * 1000))
            }
        }
        var result = Fusion.combine(evidence, weights: weights, maxFineTilt: maxFineTilt)
        // Flag a file that arrived damaged, so it is never mistaken for something
        // this app did.
        if let url = ctx.url { result.damage = PixelIntegrity.damageReport(for: url) }
        // Remember what the file's tag already does, so callers can tell a photo
        // that LOOKS wrong from one whose stored pixels merely are wrong.
        if ctx.hasExifTag, !ctx.exifPreApplied {
            result.existingTagTurn = ImageTransform.turn(fromExif: ctx.exifOrientation)
        }

        // Levelling cues often only fire once the picture is the right way up -
        // Vision's horizon detector in particular. If asked for a fine angle and
        // the turn was non-trivial, measure it again on the corrected pixels.
        if refineTilt, result.turn != .none, result.verdict != .noEvidence,
           let rotated = ImageTransform.rotate(ctx.analysis, result.turn, ctx: ctx.ciContext) {
            let ctx2 = ImageContext(url: nil, stored: rotated,
                                    maxAnalysisEdge: maxAnalysisEdge,
                                    thorough: thorough, ciContext: ctx.ciContext)
            let fineDetectors: [OrientationSignal] = [HorizonSignal(), EdgeStatsSignal(), TextSignal()]
            var fineEvidence: [Evidence] = []
            for d in fineDetectors {
                if let e = try? d.evaluate(ctx2) { fineEvidence.append(e) }
            }
            // In this frame the image is already upright, so any residual IS the tilt.
            let refined = Fusion.combine(fineEvidence.map {
                var e = $0
                e.logLikelihood = [0, 0, 0, 0]
                if e.fineAngleCW != nil { e.fineIsMod90 = true }
                return e
            }, weights: weights, maxFineTilt: maxFineTilt)
            if let t = refined.fineTiltCW {
                result.fineTiltCW = t
                result.fineTiltConfidence = refined.fineTiltConfidence
            }
            result.evidence.append(contentsOf: refined.evidence.map {
                var e = $0; e.source = $0.source + " (recheck)"; return e
            })
        }
        return result
    }

    public func analyze(url: URL, refineTilt: Bool = false) throws -> OrientationResult {
        let ctx = try ImageContext(url: url, maxAnalysisEdge: maxAnalysisEdge, thorough: thorough)
        return analyze(ctx, refineTilt: refineTilt)
    }

    // MARK: - Rendering

    /// Full-resolution corrected pixels.
    public func render(_ ctx: ImageContext,
                       result: OrientationResult,
                       applyFineTilt: Bool) throws -> CGImage {
        var img = ctx.stored
        if result.turn != .none {
            guard let r = ImageTransform.rotate(img, result.turn, ctx: ctx.ciContext) else {
                throw ImageIOError.cannotRender
            }
            img = r
        }
        if applyFineTilt, let tilt = result.fineTiltCW, abs(tilt) > 0.05 {
            guard let r = ImageTransform.rotateAndCrop(img, degreesCW: tilt, ctx: ctx.ciContext) else {
                throw ImageIOError.cannotRender
            }
            img = r
        }
        return img
    }

    // MARK: - Writing

    public struct WriteOutcome: Sendable {
        public var destination: URL
        public var lossless: Bool
        public var turn: QuarterTurn
        public var fineTiltApplied: Double?
        public var bytes: Int
    }

    /// Write the correction.
    ///
    /// In `.orientationTagOnly` - the default everywhere - this touches the
    /// orientation tag and nothing else, and proves it before replacing the file.
    /// When that is impossible it throws, naming the reason. It never falls back
    /// to re-encoding on its own; rewriting someone's pixels is a decision for
    /// the caller to make deliberately, not a consolation prize.
    public func write(_ ctx: ImageContext,
                      result: OrientationResult,
                      to destination: URL,
                      mode: SaveMode,
                      applyFineTilt: Bool) throws -> WriteOutcome {
        guard let src = ctx.url else { throw ImageIOError.cannotRender }
        let wantsFine = applyFineTilt && (result.fineTiltCW.map { abs($0) > 0.05 } ?? false)

        // Replacing through a symbolic link is ambiguous - the link or its target?
        // Rather than guess, say so.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: src.path)) != nil {
            throw ImageIOError.symbolicLink(src.lastPathComponent)
        }

        // Writing a copy must never land on top of something that is already
        // there. The chosen name is derived from the source, so a file sitting at
        // it is somebody else's photo, not a previous version of this one.
        if src != destination, FileManager.default.fileExists(atPath: destination.path) {
            throw ImageIOError.destinationExists(destination.lastPathComponent)
        }

        switch mode {
        case .orientationTagOnly:
            if wantsFine {
                throw ImageIOError.wouldRewritePixels("levelling resamples and crops the image")
            }
            if ctx.exifPreApplied {
                throw ImageIOError.wouldRewritePixels(
                    "the file's orientation tag is mirrored, which a plain turn cannot express")
            }
            guard ImageWriter.canWriteMetadataOnly(url: src, turn: result.turn) else {
                let ext = src.pathExtension.uppercased()
                throw ImageIOError.wouldRewritePixels(
                    "\(ext.isEmpty ? "this format" : ext) files carry no orientation tag")
            }
            if src != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: src, to: destination)
            }
            do {
                try ImageWriter.writeMetadataOnly(src: destination, dest: destination,
                                                  turn: result.turn)
            } catch {
                // A copy we made for this write is ours to clean up.
                if src != destination { try? FileManager.default.removeItem(at: destination) }
                throw error
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
            return WriteOutcome(destination: destination, lossless: true, turn: result.turn,
                                fineTiltApplied: nil, bytes: size)

        case .rewritePixels(let quality):
            // Re-encoding a file that is already truncated decodes the grey where
            // the data ran out and writes it back as real pixels, which destroys
            // any chance of recovering it. Never do that on its own say-so.
            if let damage = PixelIntegrity.damageReport(for: src) {
                throw ImageIOError.refusingDamagedSource(damage)
            }
            let img = try render(ctx, result: result, applyFineTilt: applyFineTilt)
            try ImageWriter.writeBaked(image: img, src: src, dest: destination, quality: quality)
            let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
            return WriteOutcome(destination: destination, lossless: false, turn: result.turn,
                                fineTiltApplied: wantsFine ? result.fineTiltCW : nil, bytes: size)
        }
    }
}
