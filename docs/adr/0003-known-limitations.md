# ADR 0003: Known limitations of the first MVP pass

## Status
Accepted (documented, not blocking — tracked here for the next iteration)

## Context
The first end-to-end implementation (reference map capture, piece segmentation, feature-print matching, zone mode, progress tracking) was built and verified to compile, pass its unit tests, and launch correctly on the iOS Simulator. It has **not** been exercised against real camera photos or a real puzzle, because the Simulator has no camera and no such test data exists yet.

## Known limitations

- **Matching confidence is an uncalibrated heuristic.** `ReferenceIndex.topMatches` converts feature-print distance to a 0–1 confidence score with a fixed linear formula (see `PuzzleAssistant/Vision/ReferenceIndex.swift`). This has not been validated against real puzzle photos and will very likely need recalibration (or a different formula entirely) once real test data exists.
- **Heavy CV/ML work runs on the main actor.** Segmentation, feature-print generation, and reference-index building currently run inside a plain `Task { }` launched from SwiftUI view code, which stays on the main actor rather than being explicitly offloaded to a background executor. It won't corrupt data, but it will visibly block the UI during processing (a "Comparing against the reference map…" spinner is shown, so it's not silent, but it isn't smooth). Proper background-actor offloading (with SwiftData's `ModelActor` for safe cross-thread persistence) is a follow-up, not yet done.
- **Piece segmentation assumes a plain, contrasting, non-overlapping layout.** It uses classical contour detection (`VNDetectContoursRequest`), not a learned model. Pieces that touch, overlap, or sit on a cluttered/textured background will likely be missed or merged — this is a fundamental limitation of the approach, not a bug to "just fix," and was flagged as a risk during planning.
- **Rotation estimation (PCA on the piece silhouette) is unreliable for near-symmetric piece shapes.** Matching compensates by also trying fixed rotation steps (every 45°), but this multiplies the matching cost and is still an approximation.
- **The reference index is rebuilt in memory every session**, not persisted across app launches, trading a few seconds of recomputation for avoiding an uncertain `VNFeaturePrintObservation` on-disk serialization path.
- **No real accuracy numbers exist yet.** The planning document was explicit that top-N match accuracy needs empirical calibration on a real puzzle before any number can be promised — that calibration has not happened.

## Consequences
This is a real, compiling, on-device implementation of the full MVP scope agreed during planning — not a stub or mockup — but its core value proposition (useful match suggestions) is unverified until tested against a physical iPhone camera and a real puzzle. The next iteration should prioritize that real-world test over further features.
