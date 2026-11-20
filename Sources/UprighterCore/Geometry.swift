import Foundation

// MARK: - Angle conventions
//
// The whole program uses ONE convention, stated here:
//
//   * A "feature angle" is the direction of something that lies HORIZONTAL in an
//     upright photo (the line between the eyes, a line of text, the horizon),
//     measured in degrees, counter-clockwise-positive, in a y-UP coordinate space
//     (which is what Vision reports).
//
//   * `rotationCW` is the clockwise rotation, in degrees, that must be APPLIED to
//     the image to make it upright.
//
// Empirically verified (see Tests): if an upright image is turned 90 degrees
// clockwise, Vision reports its eye-line / text-baseline at about -90 degrees.
// Undoing that needs a 90 degree counter-clockwise turn. So:
//
//        rotationCW = featureAngle
//
// because a clockwise rotation of -90 IS a counter-clockwise rotation of 90.

public enum Angle {
    /// Wrap to (-180, 180].
    public static func norm180(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x <= -180 { x += 360 }
        if x > 180 { x -= 360 }
        return x
    }

    /// Wrap to [0, 360).
    public static func norm360(_ d: Double) -> Double {
        let x = d.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    /// Smallest absolute difference between two angles, in degrees.
    public static func delta(_ a: Double, _ b: Double) -> Double { abs(norm180(a - b)) }

    public static func toRad(_ d: Double) -> Double { d * .pi / 180 }
    public static func toDeg(_ r: Double) -> Double { r * 180 / .pi }
}

// MARK: - Circular statistics

public enum Circular {
    /// Weighted circular mean of angles in degrees. Returns nil for empty/degenerate input.
    public static func mean(_ angles: [Double], weights: [Double]? = nil) -> Double? {
        guard !angles.isEmpty else { return nil }
        let w = weights ?? Array(repeating: 1.0, count: angles.count)
        guard w.count == angles.count else { return nil }
        var sx = 0.0, sy = 0.0
        for (a, wi) in zip(angles, w) {
            sx += wi * cos(Angle.toRad(a))
            sy += wi * sin(Angle.toRad(a))
        }
        if abs(sx) < 1e-12 && abs(sy) < 1e-12 { return nil }
        return Angle.toDeg(atan2(sy, sx))
    }

    /// Mean resultant length in [0,1]. 1 = perfectly aligned, 0 = uniformly spread.
    /// This is our measure of "do the samples agree with each other".
    public static func resultantLength(_ angles: [Double], weights: [Double]? = nil) -> Double {
        guard !angles.isEmpty else { return 0 }
        let w = weights ?? Array(repeating: 1.0, count: angles.count)
        let total = w.reduce(0, +)
        guard total > 0 else { return 0 }
        var sx = 0.0, sy = 0.0
        for (a, wi) in zip(angles, w) {
            sx += wi * cos(Angle.toRad(a))
            sy += wi * sin(Angle.toRad(a))
        }
        return min(1.0, hypot(sx, sy) / total)
    }

    /// Circular mean over angles that are only meaningful modulo `period` degrees.
    /// Used for edge/line statistics, where a line at 10 deg and one at 190 deg are
    /// the same line (period 180), and for 4-fold edge structure (period 90).
    public static func meanMod(_ angles: [Double], period: Double) -> (angle: Double, strength: Double) {
        guard !angles.isEmpty else { return (0, 0) }
        let k = 360.0 / period
        var sx = 0.0, sy = 0.0
        for a in angles {
            sx += cos(Angle.toRad(a * k))
            sy += sin(Angle.toRad(a * k))
        }
        let n = Double(angles.count)
        let strength = hypot(sx, sy) / n
        let mean = Angle.toDeg(atan2(sy, sx)) / k
        return (mean, min(1.0, strength))
    }
}

// MARK: - Quarter turns

/// The four lossless orientations. Raw value is the clockwise rotation in degrees.
public enum QuarterTurn: Int, CaseIterable, Sendable, Codable {
    case none = 0
    case cw90 = 90
    case cw180 = 180
    case cw270 = 270

    public var degreesCW: Double { Double(rawValue) }

    /// Nearest quarter turn to a continuous clockwise rotation.
    public static func nearest(toCW deg: Double) -> QuarterTurn {
        let n = Angle.norm360(deg)
        let idx = Int((n / 90).rounded()) % 4
        return QuarterTurn(rawValue: idx * 90) ?? .none
    }

    /// Residual tilt left over after snapping to this quarter turn, in (-45, 45].
    public func residual(fromCW deg: Double) -> Double {
        Angle.norm180(deg - degreesCW)
    }

    public var label: String {
        switch self {
        case .none: return "upright"
        case .cw90: return "90 CW"
        case .cw180: return "180"
        case .cw270: return "90 CCW"
        }
    }

    /// Human-readable description of what will be done to the photo.
    public var actionDescription: String {
        switch self {
        case .none: return "already upright"
        case .cw90: return "turn right 90"
        case .cw180: return "turn 180"
        case .cw270: return "turn left 90"
        }
    }

    public var inverse: QuarterTurn {
        switch self {
        case .none: return .none
        case .cw90: return .cw270
        case .cw180: return .cw180
        case .cw270: return .cw90
        }
    }

    /// Does this turn swap width and height?
    public var swapsAxes: Bool { self == .cw90 || self == .cw270 }
}
