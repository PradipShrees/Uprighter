import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOError: Error, LocalizedError {
    case cannotRead(URL)
    case cannotDecode(URL)
    case cannotRender
    case cannotWrite(URL)
    case unsupportedType(String)
    case pixelsChanged(String)
    case wouldRewritePixels(String)
    case destinationExists(String)
    case refusingDamagedSource(String)
    case symbolicLink(String)
    case integrityUnverifiable(String)

    /// True for the refusals that mean "I deliberately left this alone", as
    /// opposed to something going wrong. Both front ends report these calmly:
    /// declining to touch a photo is the app working, not failing.
    public var isDeliberateRefusal: Bool {
        switch self {
        case .wouldRewritePixels, .destinationExists, .refusingDamagedSource, .symbolicLink,
             .pixelsChanged, .integrityUnverifiable:
            return true
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let u): return "Cannot read \(u.lastPathComponent)"
        case .cannotDecode(let u): return "Not a readable image: \(u.lastPathComponent)"
        case .cannotRender: return "Failed to render the rotated image"
        case .cannotWrite(let u): return "Cannot write \(u.path)"
        case .unsupportedType(let t): return "Unsupported image type: \(t)"
        case .destinationExists(let name):
            return "Refused: \(name) already exists and is not this photo. "
                 + "Use -i to correct the original in place, or -o to write somewhere else."
        case .symbolicLink(let name):
            return "Refused: \(name) is a symbolic link. "
                 + "Point me at the file it refers to, so there is no doubt which one is written."
        case .refusingDamagedSource(let why):
            return "Refused to re-encode a damaged file: \(why) "
                 + "Re-encoding would turn that damage into permanent pixels. "
                 + "Correct it without --bake, or recover the file first."
        case .wouldRewritePixels(let why):
            return "Skipped: turning this would have to rewrite the pixels - \(why)"
        case .pixelsChanged(let d):
            return "Refused to write: it would have changed the picture - \(d)"
        case .integrityUnverifiable(let d):
            return "Refused to write: could not prove the picture was unchanged - \(d)"
        }
    }
}

/// How a correction gets written to disk.
public enum SaveMode: Sendable {
    /// Rewrite only the orientation tag. This cannot alter the picture, and the
    /// result is checked against the original before it replaces anything.
    /// If the file cannot be corrected this way, writing is REFUSED rather than
    /// quietly downgraded - a silent fall-back to re-encoding is exactly the kind
    /// of surprise this mode exists to prevent.
    case orientationTagOnly
    /// Re-encode the image. This changes every pixel and loses a generation of
    /// quality. Only ever used when explicitly asked for.
    case rewritePixels(quality: Double)
}

public enum ImageLoader {

    /// The orientation tag stored in the file, or 1 when absent.
    public static func exifOrientation(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? Int
        else { return 1 }
        return (1...8).contains(o) ? o : 1
    }

    /// True when the file actually records a tag (vs us defaulting to 1).
    public static func hasExifOrientation(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }
        return props[kCGImagePropertyOrientation] != nil
    }

    /// Decode the stored pixels, WITHOUT applying the EXIF orientation.
    /// We want the raw pixels so the detectors judge what is really there.
    public static func decodeStored(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageIOError.cannotRead(url)
        }
        guard let img = CGImageSourceCreateImageAtIndex(
            src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageIOError.cannotDecode(url) }
        return img
    }

    /// Longest-edge downscale for analysis. Returns the original when already small.
    public static func downscaled(_ img: CGImage, maxEdge: Int, ctx: CIContext) -> CGImage {
        let longest = max(img.width, img.height)
        guard longest > maxEdge, longest > 0 else { return img }
        let s = Double(maxEdge) / Double(longest)
        let ci = CIImage(cgImage: img).transformed(by: CGAffineTransform(scaleX: s, y: s))
        return ctx.createCGImage(ci, from: ci.extent) ?? img
    }

    /// EXIF orientations that include a flip. Rare, but they must be consumed
    /// before analysis or every geometric cue comes out mirrored.
    public static func isMirrored(_ o: Int) -> Bool { [2, 4, 5, 7].contains(o) }

    /// Decode the pixels the detectors should judge.
    ///
    /// Normally that is the stored pixels with the orientation tag left alone, so
    /// the tag stays an independent hypothesis. But a mirrored tag cannot be left
    /// alone - a flipped image would make every angle we measure wrong-handed - so
    /// in that case the tag is applied first and reported as consumed.
    public static func decodeForAnalysis(_ url: URL, ctx: CIContext) throws
        -> (image: CGImage, exifPreApplied: Bool, storedOrientation: Int) {
        let stored = try decodeStored(url)
        let o = exifOrientation(url)
        guard isMirrored(o) else { return (stored, false, o) }
        let ci = CIImage(cgImage: stored).oriented(forExifOrientation: Int32(o))
        guard let fixed = ctx.createCGImage(ci, from: ci.extent) else {
            return (stored, false, o)
        }
        return (fixed, true, o)
    }

    public static func isSupported(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        guard let ids = CGImageSourceCopyTypeIdentifiers() as? [String] else { return false }
        return ids.contains(t.identifier)
    }
}

public enum ImageTransform {

    /// EXIF orientation constant that expresses "apply this clockwise turn".
    static func exifConstant(for turn: QuarterTurn) -> Int32 {
        switch turn {
        case .none: return 1
        case .cw90: return 6
        case .cw180: return 3
        case .cw270: return 8
        }
    }

    /// Non-mirrored EXIF orientations expressed as a clockwise turn.
    /// Mirrored values (2,4,5,7) return nil - we bake those instead of composing.
    static func turn(fromExif o: Int) -> QuarterTurn? {
        switch o {
        // Explicit, because a bare `.none` here would mean Optional.none (nil).
        case 1: return QuarterTurn.none
        case 6: return QuarterTurn.cw90
        case 3: return QuarterTurn.cw180
        case 8: return QuarterTurn.cw270
        default: return nil
        }
    }

    /// Compose an existing orientation tag with an extra clockwise turn.
    static func composeExif(existing: Int, extra: QuarterTurn) -> Int? {
        guard let base = turn(fromExif: existing) else { return nil }
        let combined = QuarterTurn(rawValue: Int(Angle.norm360(base.degreesCW + extra.degreesCW))) ?? .none
        return Int(exifConstant(for: combined))
    }

    /// Exact quarter turn - no resampling, no quality loss.
    public static func rotate(_ img: CGImage, _ turn: QuarterTurn, ctx: CIContext) -> CGImage? {
        guard turn != .none else { return img }
        let ci = CIImage(cgImage: img).oriented(forExifOrientation: exifConstant(for: turn))
        return ctx.createCGImage(ci, from: ci.extent)
    }

    /// Arbitrary clockwise rotation, cropped back to the largest inscribed rectangle
    /// of the original aspect ratio so the result has no blank corners.
    public static func rotateAndCrop(_ img: CGImage, degreesCW: Double, ctx: CIContext) -> CGImage? {
        let residual = Angle.norm180(degreesCW)
        if abs(residual) < 0.02 { return img }
        let w = Double(img.width), h = Double(img.height)
        let ci = CIImage(cgImage: img)
            .transformed(by: CGAffineTransform(rotationAngle: Angle.toRad(-residual)))
        let ext = ci.extent
        let (cw, ch) = largestInscribedRect(w: w, h: h, degrees: residual)
        let rect = CGRect(x: ext.midX - cw / 2, y: ext.midY - ch / 2, width: cw, height: ch)
            .intersection(ext)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return ctx.createCGImage(ci, from: rect.integral)
    }

    /// Largest axis-aligned rectangle with the original aspect ratio that fits
    /// inside a w x h rectangle rotated by `degrees`.
    static func largestInscribedRect(w: Double, h: Double, degrees: Double) -> (Double, Double) {
        let a = abs(Angle.toRad(Angle.norm180(degrees)))
        let angle = a > .pi / 2 ? .pi - a : a
        let (longSide, shortSide) = w >= h ? (w, h) : (h, w)
        let sinA = sin(angle), cosA = cos(angle)
        // Standard result for the maximal inscribed rectangle of the same aspect.
        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-9 {
            let x = 0.5 * shortSide
            let (wr, hr) = w >= h ? (x / sinA, x / cosA) : (x / cosA, x / sinA)
            return (min(w, wr), min(h, hr))
        }
        let cos2A = cosA * cosA - sinA * sinA
        return (min(w, (w * cosA - h * sinA) / cos2A),
                min(h, (h * cosA - w * sinA) / cos2A))
    }
}
