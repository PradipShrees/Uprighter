import Foundation
import UprighterCore
import CoreGraphics
import CoreImage

// MARK: - Terminal helpers

let useColor = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
func c(_ s: String, _ code: String) -> String { useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func bold(_ s: String) -> String { c(s, "1") }
func dim(_ s: String) -> String { c(s, "2") }
func green(_ s: String) -> String { c(s, "32") }
func yellow(_ s: String) -> String { c(s, "33") }
func red(_ s: String) -> String { c(s, "31") }
func cyan(_ s: String) -> String { c(s, "36") }
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func padL(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
func verdictColor(_ v: Verdict, _ s: String) -> String {
    switch v {
    case .confident: return green(s)
    case .likely: return cyan(s)
    case .uncertain: return yellow(s)
    case .noEvidence: return red(s)
    }
}
func barFor(_ p: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((p * Double(width)).rounded())))
    return String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled)
}

// MARK: - Options

struct Options {
    var command = "check"
    var paths: [URL] = []
    var level = false            // apply fine tilt
    var lossless = true          // prefer metadata-only writes
    var quality = 0.95
    var inPlace = false
    var outDir: URL?
    var suffix = "-upright"
    var json = false
    var verbose = false
    var recursive = false
    var thorough = false
    var minMargin = 0.0          // skip writes below this confidence margin
    var fastText = false         // skip the upside-down re-read
    var sawBake = false          // --bake was asked for explicitly
    var dryRun = false
}

func usage() -> String {
    """
    \(bold("uprighter")) - detect which way up a photo should be, and fix it

    \(bold("USAGE"))
      uprighter check  <files-or-dirs>...     report what it finds, change nothing
      uprighter fix    <files-or-dirs>...     write the corrected photos
      uprighter bench  <files-or-dirs>...     measure accuracy on known-upright photos
      uprighter detectors                     list the cues and their weights

    \(bold("OPTIONS"))
      -r, --recursive        descend into directories
          --level            also correct residual tilt. Resamples and crops, so
                             it requires --bake.
          --bake             REWRITE PIXELS. Re-encodes every photo, losing a
                             generation of quality. Needed only for formats with
                             no orientation tag, or with --level. Off by default.
          --quality <0..1>   JPEG quality when re-encoding (default 0.95)
      -i, --in-place         overwrite the original (default: write alongside)
      -o, --out <dir>        write corrected copies into <dir>
          --suffix <s>       filename suffix for copies (default "-upright")
          --min-margin <m>   only write when the winning margin is at least m
          --thorough         larger analysis image
          --fast             skip the upside-down text re-read (faster, less accurate)
      -n, --dry-run          with `fix`, show what would happen
      -v, --verbose          show every detector, including silent ones
          --json             machine-readable output
      -h, --help             this text
    """
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") ,
       ["check", "fix", "bench", "detectors"].contains(first) {
        o.command = first
        args.removeFirst()
    }
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": print(usage()); exit(0)
        case "-r", "--recursive": o.recursive = true
        case "--level": o.level = true
        case "--bake": o.lossless = false; o.sawBake = true
        case "-i", "--in-place": o.inPlace = true
        case "-n", "--dry-run": o.dryRun = true
        case "-v", "--verbose": o.verbose = true
        case "--json": o.json = true
        case "--thorough": o.thorough = true
        case "--fast": o.fastText = true
        case "--quality":
            i += 1; o.quality = Double(args[safe: i] ?? "") ?? 0.95
        case "--min-margin":
            i += 1; o.minMargin = Double(args[safe: i] ?? "") ?? 0
        case "--suffix":
            i += 1; o.suffix = args[safe: i] ?? o.suffix
        case "-o", "--out":
            i += 1; if let p = args[safe: i] { o.outDir = URL(fileURLWithPath: p) }
        default:
            if a.hasPrefix("-") {
                FileHandle.standardError.write("unknown option: \(a)\n".data(using: .utf8)!)
                exit(2)
            }
            o.paths.append(URL(fileURLWithPath: a))
        }
        i += 1
    }
    return o
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - File collection

func collectImages(_ paths: [URL], recursive: Bool) -> [URL] {
    var out: [URL] = []
    let fm = FileManager.default
    for p in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p.path, isDirectory: &isDir) else {
            FileHandle.standardError.write("not found: \(p.path)\n".data(using: .utf8)!)
            continue
        }
        if isDir.boolValue {
            let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if recursive {
                if let e = fm.enumerator(at: p, includingPropertiesForKeys: nil, options: opts) {
                    for case let u as URL in e where ImageLoader.isSupported(u) { out.append(u) }
                }
            } else {
                let items = (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: opts)) ?? []
                out.append(contentsOf: items.filter { ImageLoader.isSupported($0) })
            }
        } else if ImageLoader.isSupported(p) {
            out.append(p)
        }
    }
    return out.sorted { $0.path < $1.path }
}

// MARK: - Reporting

func printReport(_ url: URL, _ r: OrientationResult, verbose: Bool) {
    let head = pad(url.lastPathComponent, 42)
    let action = r.needsRotation ? bold(r.displayTurn.actionDescription) : dim("already upright")
    var line = "\(head) \(verdictColor(r.verdict, pad(r.summary, 22))) \(action)"
    if let t = r.fineTiltCW {
        line += dim(String(format: "  (tilt %+.2f)", t))
    }
    if r.looksUprightAlready, r.storedPixelsNeedTurn {
        line += dim("  [tag already handles it]")
    }
    print(line)
    if let d = r.damage { print("    " + red("damaged file") + "  " + d) }
    let shown = verbose ? r.evidence : r.contributing
    for e in shown.sorted(by: { $0.confidence > $1.confidence }) {
        let p = e.ownPosterior
        let best = e.ownBest
        let bar = e.confidence > 0.02 ? barFor(p.max() ?? 0) : "----------"
        let turnStr = e.confidence > 0.02 ? best.label : "-"
        print("    " + dim(pad(e.source, 20))
              + pad(turnStr, 11)
              + dim(bar) + " "
              + padL(String(format: "%.2f", e.confidence), 5) + "  "
              + dim(e.detail))
    }
    if !shown.isEmpty { print("") }
}

func jsonObject(_ url: URL, _ r: OrientationResult) -> [String: Any] {
    [
        "file": url.path,
        "turn": r.displayTurn.rawValue,
        "storedPixelTurn": r.turn.rawValue,
        "action": r.displayTurn.actionDescription,
        "looksUprightAlready": r.looksUprightAlready,
        "verdict": r.verdict.rawValue,
        "confidence": r.confidence,
        "margin": r.margin,
        "posterior": r.posterior,
        "fineTilt": r.fineTiltCW as Any? ?? NSNull(),
        "ms": r.totalMS,
        "evidence": r.evidence.map { e in
            [
                "source": e.source,
                "best": e.ownBest.rawValue,
                "confidence": e.confidence,
                "detail": e.detail,
                "posterior": e.ownPosterior,
            ] as [String: Any]
        },
    ]
}

// MARK: - Commands

var opts = parse()
// Levelling resamples and crops, so it cannot be done without rewriting pixels.
// Rather than quietly turning on --bake, say so and stop.
if opts.level && opts.lossless && opts.command == "fix" {
    FileHandle.standardError.write(Data(
        ("--level resamples and crops the image, so it cannot keep the pixels intact.\n"
         + "Add --bake if you want that, or drop --level.\n").utf8))
    exit(2)
}
let engine = Uprighter(detectors: Uprighter.allDetectors(fastText: opts.fastText),
                       thorough: opts.thorough)

func runCheck(_ files: [URL]) {
    var results: [[String: Any]] = []
    for f in files {
        do {
            let r = try engine.analyze(url: f, refineTilt: opts.level)
            if opts.json { results.append(jsonObject(f, r)) } else { printReport(f, r, verbose: opts.verbose) }
        } catch {
            if opts.json { results.append(["file": f.path, "error": "\(error)"]) }
            else { print("\(pad(f.lastPathComponent, 42)) \(red("error")) \(error.localizedDescription)") }
        }
    }
    if opts.json, let d = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
        print(String(data: d, encoding: .utf8) ?? "[]")
    }
}

func destination(for src: URL) -> URL {
    if opts.inPlace { return src }
    let base = src.deletingPathExtension().lastPathComponent + opts.suffix
    let name = base + "." + src.pathExtension
    let dir = opts.outDir ?? src.deletingLastPathComponent()
    return dir.appendingPathComponent(name)
}

func runFix(_ files: [URL]) {
    if let d = opts.outDir {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
    var changed = 0, skipped = 0, failed = 0
    for f in files {
        do {
            let ctx = try ImageContext(url: f, thorough: opts.thorough)
            let r = engine.analyze(ctx, refineTilt: opts.level)
            let wantsFine = opts.level && (r.fineTiltCW.map { abs($0) > 0.05 } ?? false)
            let nothingToDo = !r.needsRotation && !wantsFine
            if nothingToDo {
                print("\(pad(f.lastPathComponent, 42)) \(dim("skip"))  already upright")
                skipped += 1; continue
            }
            if r.margin < opts.minMargin {
                print("\(pad(f.lastPathComponent, 42)) \(yellow("skip"))  margin \(String(format: "%.2f", r.margin)) below --min-margin")
                skipped += 1; continue
            }
            let dest = destination(for: f)
            if opts.dryRun {
                print("\(pad(f.lastPathComponent, 42)) \(cyan("would")) \(bold(r.displayTurn.actionDescription))"
                      + (wantsFine ? String(format: " + level %+.2f", r.fineTiltCW ?? 0) : "")
                      + dim(" -> \(dest.lastPathComponent)"))
                changed += 1; continue
            }
            let mode: SaveMode = opts.lossless
                ? .orientationTagOnly : .rewritePixels(quality: opts.quality)
            if let d = r.damage {
                print("\(pad(f.lastPathComponent, 42)) \(red("damaged"))  \(dim(d))")
            }
            let out = try engine.write(ctx, result: r, to: dest, mode: mode, applyFineTilt: opts.level)
            let how = out.lossless ? green("lossless") : dim("re-encoded")
            print("\(pad(f.lastPathComponent, 42)) \(bold(r.displayTurn.actionDescription))"
                  + (out.fineTiltApplied != nil ? String(format: " + level %+.2f", out.fineTiltApplied!) : "")
                  + "  \(how) " + dim("-> \(out.destination.lastPathComponent)"))
            changed += 1
        } catch let e as ImageIOError {
            // Refusing to rewrite pixels is correct behaviour, not a failure.
            if e.isDeliberateRefusal {
                print("\(pad(f.lastPathComponent, 42)) \(yellow("left alone"))  "
                      + dim(e.errorDescription ?? ""))
                skipped += 1
            } else {
                print("\(pad(f.lastPathComponent, 42)) \(red("error")) \(e.errorDescription ?? "\(e)")")
                failed += 1
            }
        } catch {
            print("\(pad(f.lastPathComponent, 42)) \(red("error")) \(error.localizedDescription)")
            failed += 1
        }
    }
    print("")
    print("\(bold("\(changed)")) corrected, \(skipped) already upright or skipped"
          + (failed > 0 ? ", \(red("\(failed) failed")) " : ""))
}

/// Accuracy harness: take photos that are ALREADY upright, turn them all four
/// ways in memory, and see whether the engine puts them back. EXIF is unavailable
/// here (there is no file), so this measures the image-based cues alone.
func runBench(_ files: [URL]) {
    let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
    var total = 0, correct = 0
    var committed = 0, committedCorrect = 0
    var declined = 0, declinedCorrect = 0
    var byTurn: [Int: (n: Int, ok: Int)] = [:]
    var confusions: [String: Int] = [:]
    var worst: [(String, String)] = []

    for f in files {
        guard let base = try? ImageLoader.decodeStored(f) else { continue }
        // Respect the file's own EXIF so the baseline really is upright.
        let o = ImageLoader.exifOrientation(f)
        var upright = base
        if o != 1 {
            let ci = CIImage(cgImage: base).oriented(forExifOrientation: Int32(o))
            upright = ciCtx.createCGImage(ci, from: ci.extent) ?? base
        }
        for applied in QuarterTurn.allCases {
            guard let turned = ImageTransform.rotate(upright, applied, ctx: ciCtx) else { continue }
            let ctx = ImageContext(url: nil, stored: turned, thorough: opts.thorough, ciContext: ciCtx)
            let r = engine.analyze(ctx)
            // Undoing a clockwise turn of `applied` needs its inverse.
            let expected = applied.inverse
            total += 1
            let commits = r.verdict == .confident || r.verdict == .likely
            if commits { committed += 1 } else { declined += 1 }
            var e = byTurn[applied.rawValue] ?? (0, 0); e.n += 1
            if r.turn == expected {
                correct += 1; e.ok += 1
                if commits { committedCorrect += 1 } else { declinedCorrect += 1 }
            }
            else {
                confusions["\(applied.label) read as \(r.turn.label)", default: 0] += 1
                if worst.count < 12 {
                    worst.append((f.lastPathComponent,
                        "turned \(applied.label) -> said \(r.turn.label) (\(r.verdict.rawValue), margin \(String(format: "%.2f", r.margin)))"))
                }
            }
            byTurn[applied.rawValue] = e
        }
    }
    guard total > 0 else { print("no usable images"); return }
    print("")
    print(bold("Accuracy on \(total) rotations of \(files.count) photo(s)"))
    print("  overall      \(bold(String(format: "%.1f%%", Double(correct) / Double(total) * 100)))  (\(correct)/\(total))")
    if committed > 0 {
        print("  when it commits  \(bold(String(format: "%.1f%%", Double(committedCorrect) / Double(committed) * 100)))"
              + "  (\(committedCorrect)/\(committed))  " + dim("<- the number that matters for auto-fixing"))
    }
    if declined > 0 {
        print("  when unsure      \(String(format: "%.1f%%", Double(declinedCorrect) / Double(declined) * 100))"
              + "  (\(declinedCorrect)/\(declined))  " + dim("flagged for a human; \(String(format: "%.0f%%", Double(declined) / Double(total) * 100)) of all"))
    }
    for t in QuarterTurn.allCases {
        if let e = byTurn[t.rawValue], e.n > 0 {
            print("  \(pad("turned " + t.label, 18))\(String(format: "%5.1f%%", Double(e.ok) / Double(e.n) * 100))  (\(e.ok)/\(e.n))")
        }
    }
    if !confusions.isEmpty {
        print("\n" + bold("Mistakes"))
        for (k, v) in confusions.sorted(by: { $0.value > $1.value }) { print("  \(pad(k, 36)) x\(v)") }
        print("\n" + dim("examples:"))
        for (file, note) in worst { print(dim("  \(pad(file, 40)) \(note)")) }
    }
}

func runDetectors() {
    print(bold("\nCues, strongest first\n"))
    let ds = Uprighter.allDetectors()
    let w = Fusion.defaultWeights
    for d in ds.sorted(by: { (w[$0.name] ?? 0) > (w[$1.name] ?? 0) }) {
        let weight = w[d.name] ?? 0
        let label = weight == 0 ? dim("levelling only") : String(format: "%.2f", weight)
        print("  \(pad(d.name, 20)) \(padL(label, 14))  \(dim(d.blurb))")
    }
    print("")
}

// MARK: - Dispatch

switch opts.command {
case "detectors":
    runDetectors()
default:
    guard !opts.paths.isEmpty else { print(usage()); exit(2) }
    let files = collectImages(opts.paths, recursive: opts.recursive)
    guard !files.isEmpty else {
        FileHandle.standardError.write("no readable images found\n".data(using: .utf8)!)
        exit(1)
    }
    switch opts.command {
    case "fix": runFix(files)
    case "bench": runBench(files)
    default: runCheck(files)
    }
}
