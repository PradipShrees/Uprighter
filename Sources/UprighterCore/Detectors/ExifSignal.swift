import Foundation

/// The orientation tag the file already carries.
///
/// We deliberately decode the STORED pixels and ignore this tag, which makes the
/// tag an independent hypothesis rather than something already baked in. When a
/// camera wrote `6` it is usually right, so this gets real weight - but it is a
/// claim, not a measurement, and the image-based detectors can outvote it. A tag
/// of `1` is treated as no opinion, because countless tools write `1` blindly
/// after stripping the real value, which is the very bug this app exists to fix.
public struct ExifSignal: OrientationSignal {
    public let name = "EXIF tag"
    public let blurb = "The rotation the file's own metadata claims it needs"

    public init() {}

    public func evaluate(_ ctx: ImageContext) throws -> Evidence {
        guard ctx.hasExifTag else { return .empty(name, "no orientation tag") }
        guard !ctx.exifPreApplied else {
            return .empty(name, "mirrored tag \(ctx.exifOrientation) already applied")
        }
        let o = ctx.exifOrientation
        guard o != 1 else { return .empty(name, "tag is 1 (treated as no claim)") }
        guard let turn = ImageTransform.turn(fromExif: o) else {
            return .empty(name, "tag \(o) is mirrored; ignoring")
        }
        var ll = [Double](repeating: 0, count: 4)
        if let i = QuarterTurn.allCases.firstIndex(of: turn) { ll[i] = 3.0 }
        return Evidence(source: name,
                        logLikelihood: ll,
                        confidence: 0.8,
                        detail: "tag \(o) means \(turn.actionDescription)")
    }
}
