import Foundation
import CoreGraphics
import CoreImage
import Vision

/// A small grayscale/colour grid used by the statistical detectors.
public struct PixelGrid: Sendable {
    public let width: Int
    public let height: Int
    public var luma: [Float]      // 0...1, row 0 is the TOP row of the image
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    @inline(__always) public func lumaAt(_ x: Int, _ y: Int) -> Float { luma[y * width + x] }
}

/// Everything the detectors share for one image: the decoded pixels, a reusable
/// Vision handler, and lazily cached results so no request runs twice.
public final class ImageContext {
    public let url: URL?
    /// Full-resolution stored pixels (EXIF NOT applied).
    public let stored: CGImage
    /// Downscaled copy the detectors actually look at.
    public let analysis: CGImage
    public let exifOrientation: Int
    public let hasExifTag: Bool
    /// True when a mirrored orientation tag was already applied to `stored`,
    /// which means the tag must not be counted as evidence again.
    public let exifPreApplied: Bool
    public let ciContext: CIContext

    /// Set when the caller wants the slower, more thorough passes.
    public let thorough: Bool

    private let handler: VNImageRequestHandler
    private var rotatedHandlers: [Int: VNImageRequestHandler] = [:]
    private var rotatedImages: [Int: CGImage] = [:]

    private var _faces: [VNFaceObservation]??
    private var _textByTurn: [Int: [VNRecognizedTextObservation]] = [:]
    private var _bodies: [VNHumanBodyPoseObservation]??
    private var _horizon: VNHorizonObservation???
    private var _saliency: VNSaliencyImageObservation???
    private var _classifications: [Int: [VNClassificationObservation]] = [:]
    private var _grid: PixelGrid??

    public init(url: URL?,
                stored: CGImage,
                maxAnalysisEdge: Int = 1400,
                thorough: Bool = false,
                exifPreApplied: Bool = false,
                ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
        self.url = url
        self.stored = stored
        self.exifPreApplied = exifPreApplied
        self.ciContext = ciContext
        self.thorough = thorough
        self.analysis = ImageLoader.downscaled(stored, maxEdge: maxAnalysisEdge, ctx: ciContext)
        self.exifOrientation = url.map { ImageLoader.exifOrientation($0) } ?? 1
        self.hasExifTag = url.map { ImageLoader.hasExifOrientation($0) } ?? false
        self.handler = VNImageRequestHandler(cgImage: analysis, options: [:])
    }

    public convenience init(url: URL, maxAnalysisEdge: Int = 1400, thorough: Bool = false) throws {
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let d = try ImageLoader.decodeForAnalysis(url, ctx: ctx)
        self.init(url: url, stored: d.image, maxAnalysisEdge: maxAnalysisEdge,
                  thorough: thorough, exifPreApplied: d.exifPreApplied, ciContext: ctx)
    }

    public var analysisSize: CGSize {
        CGSize(width: analysis.width, height: analysis.height)
    }

    // MARK: - Vision results, computed once each

    private func perform(_ requests: [VNRequest], on h: VNImageRequestHandler) {
        do { try h.perform(requests) } catch { /* detectors treat nil as "nothing found" */ }
    }

    public func faces() -> [VNFaceObservation] {
        if let c = _faces { return c ?? [] }
        let req = VNDetectFaceLandmarksRequest()
        if let best = VNDetectFaceLandmarksRequest.supportedRevisions.max() { req.revision = best }
        perform([req], on: handler)
        let r = req.results ?? []
        _faces = .some(r)
        return r
    }

    public func textLines() -> [VNRecognizedTextObservation] { textLines(.none) }

    /// Text lines read from the image turned by `turn`, cached per turn.
    ///
    /// Reading the SAME picture at more than one turn is not redundant. Vision
    /// decides internally whether it is looking at upside-down text, and that
    /// decision is unstable: two renderings of one 180-degree-rotated screenshot
    /// that differ only in downscale filtering gave 3368 characters labelled 180
    /// and 986 characters labelled 0. It reads far less text when it guesses the
    /// flip wrongly, so comparing how MUCH text comes back at opposing turns
    /// settles the flip reliably.
    public func textLines(_ turn: QuarterTurn) -> [VNRecognizedTextObservation] {
        if let c = _textByTurn[turn.rawValue] { return c }
        let req = VNRecognizeTextRequest()
        // Must be .accurate: .fast is not rotation invariant at all. On a
        // screenshot turned 90 degrees it found only a few accidental horizontal
        // fragments and reported their baseline as 0 - a confident vote for
        // "already upright" built on nothing.
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false   // we want geometry, not spelling
        // Revision 3 is the only one that reports a 180-degree baseline at all;
        // revisions 1 and 2 silently rectify and always claim 0.
        if let best = VNRecognizeTextRequest.supportedRevisions.max() { req.revision = best }
        perform([req], on: handlerFor(turn))
        let r = req.results ?? []
        _textByTurn[turn.rawValue] = r
        return r
    }

    /// A Vision handler for the image turned by `turn`, reusing the cached one.
    private func handlerFor(_ turn: QuarterTurn) -> VNImageRequestHandler {
        if turn == .none { return handler }
        if let cached = rotatedHandlers[turn.rawValue] { return cached }
        let h = VNImageRequestHandler(cgImage: rotatedAnalysis(turn), options: [:])
        rotatedHandlers[turn.rawValue] = h
        return h
    }

    /// Pixel size of the analysis image once turned by `turn`.
    public func analysisSize(_ turn: QuarterTurn) -> CGSize {
        turn.swapsAxes ? CGSize(width: analysis.height, height: analysis.width) : analysisSize
    }

    public func bodies() -> [VNHumanBodyPoseObservation] {
        if let c = _bodies { return c ?? [] }
        let req = VNDetectHumanBodyPoseRequest()
        perform([req], on: handler)
        let r = req.results ?? []
        _bodies = .some(r)
        return r
    }

    public func horizon() -> VNHorizonObservation? {
        if let c = _horizon { return c ?? nil }
        let req = VNDetectHorizonRequest()
        perform([req], on: handler)
        let r = req.results?.first
        _horizon = .some(r)
        return r
    }

    public func saliency() -> VNSaliencyImageObservation? {
        if let c = _saliency { return c ?? nil }
        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        perform([req], on: handler)
        let r = req.results?.first
        _saliency = .some(r)
        return r
    }

    /// Analysis image turned by `turn`, cached.
    public func rotatedAnalysis(_ turn: QuarterTurn) -> CGImage {
        if turn == .none { return analysis }
        if let c = rotatedImages[turn.rawValue] { return c }
        let r = ImageTransform.rotate(analysis, turn, ctx: ciContext) ?? analysis
        rotatedImages[turn.rawValue] = r
        return r
    }

    /// Scene classifications for a given turn. Used to ask "which way up does
    /// this look most like a normal photograph?".
    public func classifications(_ turn: QuarterTurn) -> [VNClassificationObservation] {
        if let c = _classifications[turn.rawValue] { return c }
        let req = VNClassifyImageRequest()
        perform([req], on: handlerFor(turn))
        let r = req.results ?? []
        _classifications[turn.rawValue] = r
        return r
    }

    // MARK: - Raw pixels for the statistical detectors

    /// Small RGB/luma grid with row 0 at the TOP of the image.
    public func grid(maxEdge: Int = 256) -> PixelGrid? {
        if let c = _grid { return c ?? nil }
        let g = Self.makeGrid(analysis, maxEdge: maxEdge, ctx: ciContext)
        _grid = .some(g)
        return g
    }

    static func makeGrid(_ img: CGImage, maxEdge: Int, ctx: CIContext) -> PixelGrid? {
        let small = ImageLoader.downscaled(img, maxEdge: maxEdge, ctx: ctx)
        let w = small.width, h = small.height
        guard w > 1, h > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var drew = false
        bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            c.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
            drew = true
        }
        guard drew else { return nil }
        var luma = [Float](repeating: 0, count: w * h)
        var r = luma, g = luma, b = luma
        // A CGBitmapContext stores its first memory row as the image's TOP row, so
        // the rows already arrive in the order this grid promises. (An earlier
        // version flipped here, on the assumption that the y-up drawing origin
        // also reversed memory order. It does not, and the flip silently inverted
        // every top-versus-bottom judgement: sky/ground voted for exactly the
        // wrong one of upright/180, and the edge-grid tilt came out sign-flipped.)
        for y in 0..<h {
            let srcRow = y * w * 4
            let dstRow = y * w
            for x in 0..<w {
                let i = srcRow + x * 4
                let rf = Float(bytes[i]) / 255, gf = Float(bytes[i + 1]) / 255, bf = Float(bytes[i + 2]) / 255
                r[dstRow + x] = rf; g[dstRow + x] = gf; b[dstRow + x] = bf
                luma[dstRow + x] = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            }
        }
        return PixelGrid(width: w, height: h, luma: luma, red: r, green: g, blue: b)
    }
}
