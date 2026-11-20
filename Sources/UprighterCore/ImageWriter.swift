import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ImageWriter {

    /// Whether this file's orientation can be corrected without touching the
    /// picture. False means the only way to turn it would be to rewrite the
    /// pixels - which callers must refuse rather than do quietly.
    public static func canWriteMetadataOnly(url: URL, turn: QuarterTurn) -> Bool {
        guard turn != .none else { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        // Orientation tags are meaningful for these; PNG has no standard one.
        let ok: [UTType] = [.jpeg, .tiff, .heic, .heif]
        guard ok.contains(where: { type.conforms(to: $0) }) else { return false }
        // A mirrored original cannot be expressed by replacing the tag with a
        // plain rotation without silently dropping the flip.
        return !ImageLoader.isMirrored(ImageLoader.exifOrientation(url))
    }

    /// Orientation-tag rewrite that cannot alter the picture. `dest` may equal `src`.
    ///
    /// `turn` is the rotation the STORED pixels need, which is exactly what an
    /// orientation tag expresses, so the tag is replaced rather than composed.
    ///
    /// The new file is fingerprinted and compared with the original BEFORE it is
    /// allowed to replace anything. That ordering is the whole point: if the check
    /// fails, or cannot be made, the temporary file is discarded and the original
    /// is never opened for writing at all.
    public static func writeMetadataOnly(src: URL, dest: URL, turn: QuarterTurn) throws {
        guard !ImageLoader.isMirrored(ImageLoader.exifOrientation(src)) else {
            throw ImageIOError.unsupportedType("mirrored original")
        }
        let newOrientation = Int(ImageTransform.exifConstant(for: turn))
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { throw ImageIOError.cannotRead(src) }

        // Record what must not change, before anything is written.
        let before = try PixelIntegrity.fingerprint(of: src)

        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".uprighter-\(UUID().uuidString).tmp")
        func discardTemp() { try? FileManager.default.removeItem(at: tmp) }

        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw ImageIOError.cannotWrite(dest)
        }
        let opts: [CFString: Any] = [kCGImageDestinationOrientation: newOrientation]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(d, source, opts as CFDictionary, &err) else {
            discardTemp()
            throw ImageIOError.cannotWrite(dest)
        }

        // The picture must be untouched...
        do {
            try PixelIntegrity.assertSamePicture(original: before, candidate: tmp)
        } catch {
            discardTemp()
            throw error
        }
        // ...and the tag must actually say what we meant, or the write achieved
        // nothing and should not stand.
        let written = ImageLoader.exifOrientation(tmp)
        guard written == newOrientation else {
            discardTemp()
            throw ImageIOError.integrityUnverifiable(
                "orientation tag came back as \(written), expected \(newOrientation)")
        }

        try replaceItem(at: dest, with: tmp)
    }

    /// Re-encode corrected pixels, carrying metadata over and resetting orientation.
    ///
    /// This REWRITES EVERY PIXEL through the encoder. It exists for formats that
    /// cannot carry an orientation tag and for fine levelling, and it is never
    /// reached by accident: callers must ask for it explicitly.
    public static func writeBaked(image: CGImage,
                                  src: URL?,
                                  dest: URL,
                                  quality: Double) throws {
        let ext = dest.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .jpeg
        // PNG/other lossless targets ignore the quality hint.
        let destType = (CGImageSourceCopyTypeIdentifiers() as? [String])?
            .contains(type.identifier) == true ? type : .jpeg

        var props: [CFString: Any] = [:]
        if let src, let s = CGImageSourceCreateWithURL(src as CFURL, nil),
           let existing = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] {
            props = existing
            // Pixels are now upright, so any stored transform must be cleared.
            props[kCGImagePropertyOrientation] = 1
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            // Stale pixel dimensions would contradict the new pixels.
            props.removeValue(forKey: kCGImagePropertyPixelWidth)
            props.removeValue(forKey: kCGImagePropertyPixelHeight)
        } else {
            props[kCGImagePropertyOrientation] = 1
        }
        props[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, quality))

        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".uprighter-\(UUID().uuidString).tmp")
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, destType.identifier as CFString, 1, nil) else {
            throw ImageIOError.cannotWrite(dest)
        }
        CGImageDestinationAddImage(d, image, props as CFDictionary)
        guard CGImageDestinationFinalize(d) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ImageIOError.cannotWrite(dest)
        }
        try replaceItem(at: dest, with: tmp)
    }

    /// Atomic-ish move that also works when `dest` does not exist yet.
    private static func replaceItem(at dest: URL, with tmp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }
}
