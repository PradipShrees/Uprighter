# Roadmap

- **Gate the face cue on minimum face size.** The one *confident* error in the
  42-photo test was a plaza shot taken from directly above: Vision found a face a
  few pixels across among the overhead figures and reported an eye line at
  confidence 1.00. A face below roughly 2% of the frame should not carry full
  weight.
- **Burst consistency.** Photos taken seconds apart are nearly always the same way
  up, so a confident neighbour could carry an ambiguous frame. Likely the single
  biggest accuracy win still available.
- **Live Photos.** The `.heic` gets turned and the paired `.mov` does not, so they
  desync. At minimum, warn.
- **Signing.** The app is ad-hoc signed, so its signature changes on every `make`
  and a removable-volume permission grant can reset after a rebuild. The CLI is
  the more reliable route for a large batch.
- **HEIC auxiliary images.** The `--bake` path writes a single image, so depth
  maps and HDR gain maps would not carry over. The default tag-only path is
  unaffected.
