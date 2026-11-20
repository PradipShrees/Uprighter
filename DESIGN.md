# How Uprighter works

## The cues

Nine detectors each return a score for all four quarter turns plus how much they
trust themselves on that image. The scores are combined as weighted
log-likelihoods. Several are deliberately weak — they exist to break ties when
the strong ones are silent.

| Cue | Weight | Basis |
|---|---|---|
| Face / eyes | 1.00 | Angle of the eye line, cross-checked against eyes→mouth |
| Text lines | 1.00 | Direction of recognised text baselines |
| EXIF tag | 0.90 | What the file's own metadata claims |
| Body pose | 0.65 | Hip-to-shoulder axis of detected people |
| Scene model | 0.60 | How far classifier confidence drops at each turn |
| Sky / ground | 0.50 | Brightness, blueness and texture across opposite edges |
| Edge grid | 0.45 | Distance of straight edges from a horizontal/vertical grid |
| Subject placement | 0.22 | Whether the salient subject sits above centre |
| Horizon | levelling | Apple's horizon detector — tilt only, no vote on which way is up |

## What measurement changed

Most of the design came from testing assumptions rather than trusting them.

**Vision's face detector is already rotation-invariant.** It finds faces at any
in-plane angle, and labels left and right eye correctly even upside down, so the
eye line alone resolves a full 360°.

**`VNFaceObservation.roll` is quantised to 30° steps.** Rotating a photo by 20°
and by 45° both reported −30°. The landmarks are continuous and accurate to about
a degree, so the eye line does the real work.

**Counting recognised characters is useless.** Vision reads text at any rotation
— about 4850 characters at all four turns of one screenshot. What *is*
informative is the per-line quadrilateral, whose top edge runs along the
baseline. That tracked true rotation to within 0.2°.

**But only at text revision 3.** Revisions 1 and 2 silently rectify upside-down
text and always report a baseline of 0.

**And `.fast` recognition is not rotation-invariant at all.** On a screenshot
turned 90° it found a handful of accidental horizontal fragments and reported
their baseline as 0 — a confident vote for "already upright" built on nothing.
That one setting was the difference between 27% and 82% accuracy.

**Vision's 0-versus-180 text decision is unstable.** Two renderings of the same
180°-rotated screenshot, differing only in downscale filtering, gave "3368
characters at 180" and "986 characters at 0". The axis was right both times; the
flip was not. So the baseline fixes the axis, and the flip is settled by
re-reading the picture the other way up and comparing how much text comes back.

**The pixel grid was upside down.** A `CGBitmapContext` already stores its first
memory row as the image's top row, but the grid builder flipped it anyway. That
silently inverted every top-versus-bottom judgement — a photo with blue sky
across the top was reported as "bottom edge looks most like sky". Fixing it took
accuracy from 91.5% to 93.2%.

**Face bounding boxes are square**, so their aspect ratio carries no orientation
information. That idea was dropped.

## Accuracy

Measured by taking photos known to be upright, turning them all four ways, and
checking whether the engine puts them back. `make bench DIR=...` runs this on
your own photos; the set must genuinely be upright or the ground truth is wrong.

Across 168 rotations of 42 photographs:

```
overall           96.4%
when it commits   99.4%
declines           5%
```

**Where it struggles:** flat-lay and top-down shots, close-up textures, symmetric
or abstract artwork, reflective still lifes, and night scenes with no sky. Those
often have no correct answer — a circuit board photographed from directly above
is equally valid either way up. Faces, people, text, buildings and landscapes are
comfortable. Use `--min-margin` to act only on the confident calls.

## The safety model

Correcting orientation should change the orientation tag and nothing else. That
is checked rather than assumed.

For JPEG the check hashes the entropy-coded scan plus the DQT/DHT/SOF segments
that decode it, skipping the APPn and COM segments where metadata lives. Exact
and nearly free. For other formats the decoded pixels are hashed instead.

The new file is fingerprinted and compared **before** it is allowed to replace
anything. That ordering is the point: a failed check discards the temporary file
and the original is never opened for writing. Verified — a tag rewrite leaves the
hash identical, a re-encode is detected, and flipping a single bit inside the
scan data is detected.

### Everything it refuses to do

| Situation | What happens |
|---|---|
| PNG, or any format with no orientation tag | Left byte-identical, reason shown |
| A file already damaged, with `--bake` | Refused — re-encoding would make the damage permanent |
| Output name already taken by another photo | Refused — use `-i` or `-o` |
| A mirrored orientation tag | Left alone; a plain turn cannot express it |
| A symbolic link | Refused — point it at the real file |
| `--level` without `--bake` | Stops; levelling resamples and crops |
| Disk full, or no write permission | Clean error, original byte-identical, no temp left |
| Killed mid-batch (`SIGKILL`) | 44/44 intact, 0 corrupt, 0 altered, no temp files |
| Run twice | Second run is a no-op |

Verified on APFS, HFS+ and exFAT volumes: 0 of 20 photos had image data altered,
nothing moved, no stray files, and the only size change was ~150 bytes of
metadata per photo.

## Other cues considered

Not implemented, roughly in order of promise:

- **A purpose-trained rotation network.** Self-supervised: rotate any corpus at
  random and train a four-way classifier. The scene-model cue approximates this
  for free; a real one would beat every statistical cue here.
- **Monocular depth.** In an upright photo the ground plane recedes with
  distance. This works on exactly the gravity-free scenes that defeat everything
  else.
- **Asking a vision-language model.** Very accurate, but needs a network round
  trip and sends the photo off the machine. Both are against the point.
- **Vanishing points.** Verticals converge above or below the frame, never to the
  side.
- **Object detectors with a canonical pose** — cars, bottles, chairs, plates.
- **Burst and session consistency.** Photos taken seconds apart are almost always
  the same way up. The cheapest real win left.

## Building without Xcode

The build is driven by `swiftc` straight from the `Makefile` rather than Swift
Package Manager, because the SwiftPM shipped in these Command Line Tools is
broken: its `PackageDescription.swiftmodule` declares `swiftLanguageVersions`
while the dylib only exports `swiftLanguageModes`, so no manifest will link.

SwiftUI's `@State` is a macro whose plugin (`libSwiftUIMacros.dylib`) ships only
with full Xcode, so view state lives in observable objects instead. Every other
SwiftUI property wrapper works fine.

## Layout

```
Sources/UprighterCore/      the engine, no UI
  Geometry.swift            angle conventions and circular statistics
  ImageIO.swift             decoding, exact quarter turns, save modes
  ImageWriter.swift         verified tag rewrite; re-encode kept separate
  PixelIntegrity.swift      the proof that a write changed nothing
  ImageContext.swift        one shared Vision pass per image, cached per turn
  Signal.swift              what a cue reports
  Fusion.swift              combining cues; confidence and verdicts
  Uprighter.swift           the pipeline
  Detectors/                the nine cues, one file each
Sources/UprighterCLI/       the `uprighter` command
Sources/UprighterApp/       the window
```

The angle convention is stated once, at the top of `Geometry.swift`, and
everything obeys it.
