import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Proof that a rewrite did not touch the picture itself.
///
/// Turning a photo upright should change the orientation tag and nothing else -
/// not one pixel. That is easy to claim and easy to get wrong, so instead of
/// trusting the write path, every write is checked against this before it is
/// allowed to replace anything.
///
/// For JPEG the check is exact and costs almost nothing: the compressed image is
/// carried in the entropy-coded scan segments, and the tables and frame header
/// that decode them are carried in DQT/DHT/SOF. Fingerprint those and ignore the
/// APPn and comment segments, which is exactly where metadata lives. If the
/// fingerprint matches, the decoded pixels cannot differ.
///
/// For other formats there is no equally cheap structural answer, so the pixels
/// themselves are decoded and hashed. Slower, same guarantee.
public enum PixelIntegrity {

    public struct Fingerprint: Equatable, Sendable {
        /// How it was computed, so two fingerprints are never compared across methods.
        public let method: String
        public let digest: String
        /// Size of the data that was hashed, purely for diagnostics.
        public let byteCount: Int
    }

    // MARK: - Public

    /// Fingerprint the image content of a file.
    public static func fingerprint(of url: URL) throws -> Fingerprint {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let jpeg = jpegFingerprint(data) { return jpeg }
        return try decodedPixelFingerprint(url)
    }

    /// Throw unless `candidate` carries exactly the same picture as `original`.
    public static func assertSamePicture(original: Fingerprint, candidate: URL) throws {
        let now = try fingerprint(of: candidate)
        guard now.method == original.method else {
            throw ImageIOError.integrityUnverifiable(
                "fingerprint method changed (\(original.method) -> \(now.method))")
        }
        guard now.digest == original.digest else {
            throw ImageIOError.pixelsChanged(
                "image data differs after the rewrite "
                + "(\(original.byteCount) -> \(now.byteCount) bytes of image content)")
        }
    }

    // MARK: - Is the file itself intact?

    /// A complete JPEG ends with an EOI marker. A file that stops before one was
    /// cut short somewhere - a bad card, an interrupted copy, a drive that
    /// dropped out - and will decode with flat grey where the data ran out.
    ///
    /// This is reported, never acted on. The photo is still turned, because
    /// rewriting the orientation tag does not touch the damaged data and leaves
    /// the file exactly as recoverable as it was. The point is that you should
    /// know, rather than find out later.
    public static func damageReport(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 4 else { return nil }
        let start = data.startIndex
        guard data[start] == 0xFF, data[start + 1] == 0xD8 else { return nil }  // not JPEG

        // Allow trailing padding, which some cameras append.
        var i = data.endIndex - 1
        let floor = max(start, data.endIndex - 64)
        while i > floor, data[i] == 0x00 { i -= 1 }
        guard i > start else { return "file is empty" }
        if data[i] == 0xD9, data[i - 1] == 0xFF { return nil }   // healthy

        let kb = data.count / 1024
        return "incomplete file - the JPEG data stops before the end marker "
             + "(\(kb) KB). Part of the picture will show as grey. "
             + "Turning it is safe and changes nothing, but the file itself is damaged."
    }

    // MARK: - JPEG

    /// Hash everything in a JPEG that affects the decoded image, skipping the
    /// APPn and COM segments where metadata lives. Returns nil when the file is
    /// not a JPEG we can walk confidently.
    static func jpegFingerprint(_ data: Data) -> Fingerprint? {
        guard data.count > 4, data[data.startIndex] == 0xFF,
              data[data.startIndex + 1] == 0xD8 else { return nil }

        var hasher = SHA256()
        var hashed = 0
        var sawScan = false
        let base = data.startIndex
        var i = base + 2

        @inline(__always) func byte(_ k: Int) -> UInt8 { data[k] }

        while i + 1 < data.endIndex {
            guard byte(i) == 0xFF else { return nil }     // not a well-formed stream
            var marker = byte(i + 1)
            var mi = i
            // Fill bytes: any number of 0xFF may pad before a marker.
            while marker == 0xFF, mi + 2 < data.endIndex {
                mi += 1
                marker = byte(mi + 1)
            }
            // Standalone markers carry no payload.
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                i = mi + 2
                continue
            }
            if marker == 0xD9 { break }                   // EOI
            guard mi + 3 < data.endIndex else { return nil }
            let length = Int(byte(mi + 2)) << 8 | Int(byte(mi + 3))
            guard length >= 2, mi + 2 + length <= data.endIndex else { return nil }

            let isMetadata = (marker >= 0xE0 && marker <= 0xEF) || marker == 0xFE
            if !isMetadata {
                // Tables, frame headers and scan headers all decide the pixels.
                let seg = data[mi..<(mi + 2 + length)]
                hasher.update(data: seg)
                hashed += seg.count
            }

            if marker == 0xDA {                            // start of scan
                sawScan = true
                var j = mi + 2 + length
                let start = j
                while j + 1 < data.endIndex {
                    if byte(j) == 0xFF {
                        let next = byte(j + 1)
                        // Stuffed 0xFF00 and restart markers belong to the scan.
                        if next == 0x00 || (next >= 0xD0 && next <= 0xD7) { j += 2; continue }
                        if next == 0xFF { j += 1; continue }
                        break
                    }
                    j += 1
                }
                let scan = data[start..<min(j, data.endIndex)]
                hasher.update(data: scan)
                hashed += scan.count
                i = j
            } else {
                i = mi + 2 + length
            }
        }

        guard sawScan, hashed > 0 else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Fingerprint(method: "jpeg-scan", digest: digest, byteCount: hashed)
    }

    // MARK: - Everything else

    /// Decode the stored pixels and hash them. The orientation tag is deliberately
    /// NOT applied, so a change to the tag alone leaves this untouched - which is
    /// exactly the change we are trying to permit.
    static func decodedPixelFingerprint(_ url: URL) throws -> Fingerprint {
        let img = try ImageLoader.decodeStored(url)
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { throw ImageIOError.cannotDecode(url) }

        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var drew = false
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            drew = true
        }
        guard drew else { throw ImageIOError.cannotDecode(url) }

        var hasher = SHA256()
        hasher.update(data: Data("\(w)x\(h)".utf8))
        buffer.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Fingerprint(method: "decoded-pixels", digest: digest, byteCount: buffer.count)
    }
}
