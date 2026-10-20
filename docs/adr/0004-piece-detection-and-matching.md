# ADR 0004: Piece detection and matching algorithm

## Status
Accepted (validated on the Python test bench in `tools/piece_matching/`, 2026-10-19)

## Context
ADR 0002 planned classical segmentation against a plain background. Tests on real photos
(iPhone 15 Pro Max, ~3000 loose pieces on paper/cardboard, many touching) showed that
classical methods cannot separate touching pieces: a seam between two pieces looks the
same as a line printed in the picture.

Tried and **rejected** for outlining pieces:

| Method | Problem |
|---|---|
| Background colour model (Lab k-means) | light pieces merge with the paper |
| CLAHE contrast + Otsu black/white | same; printed lines split pieces |
| Canny edges | too many edges from the printed picture itself |
| Black-hat "dark seam" detection | lines inside pieces are just as dark as seams |
| Distance-transform watershed / GrabCut | works only when pieces do not touch |

## Decision

### 1. Reference picture
1. Find the photo of the full picture: the largest rectangular region whose colours
   differ from the photo border (table).
2. Refine the 4 corners with robust (Huber) line fits on each side, then
   perspective-correct to an exact rectangle.
3. Optionally split it into a grid of N cells (N = piece count) to report locations as
   row/column.

### 2. Piece segmentation — Segment Anything (SAM 2.1)
- Model: **SAM 2.1 base** (`sam2.1_b.pt`, via `ultralytics`); MobileSAM is a faster,
  slightly worse fallback. On iOS: a Core ML conversion of SAM 2.1 tiny/small.
- One point on a piece -> a precise mask of the whole piece, including tabs, even when it
  touches neighbours.
- To find all pieces automatically: a grid of prompt points (~2 per piece width) over
  overlapping 1024 px tiles at half resolution; every point gives a candidate mask.
- Keep a mask only if it looks like **one** classic piece:
  - solidity (area / convex hull) 0.55–0.97 (tabs/blanks make it non-convex);
  - aspect ratio < 1.8;
  - < 15 % background pixels (background = table colour **and** smooth, because light
    pieces match the paper colour and dark pieces are smooth);
  - area 0.5–1.5 × the typical piece area;
  - not inside the already assembled region; not overlapping an accepted piece.
- Highest SAM confidence wins on duplicates; a second pass prompts uncovered areas.

### 3. Orientation
Pieces sit upright in the finished puzzle, so arbitrary angles are not searched. The
dominant direction of the straight outline segments (length-weighted histogram mod 90°)
gives the body square orientation; only 0/90/180/270° are then tried (± 2.5° refine).

### 4. Matching on the reference
1. Colour transfer (Reinhard, Lab mean/std) from the piece photo to the reference's
   lighting.
2. Scale: reference px per photo px, from the photo-to-reference scale calibration on the
   already assembled area (or a fixed capture distance).
3. Coarse search: FFT `matchTemplate` (TM_CCOEFF_NORMED) of the piece, background filled
   with its mean colour, on a 0.4× reference, for 4 rotations × 3 scales, minus a penalty
   for mean Lab colour difference (NCC alone ignores the overall hue).
4. Fine search: masked NCC (exact piece outline) at full resolution around the top
   candidates.
5. Probability: softmax over the distinct candidates plus an implicit "somewhere else"
   option; show only candidates ≥ 5 %.

## Results (test photos)
- SAM outlines: whole pieces with tabs, correct also for touching pieces.
- Matching: pieces with distinctive content (a cat, a face, a light stripe pattern) are
  located with 45–100 %; flat areas (sky, water, foliage) give no confident place, and
  the method says so instead of guessing.
- Speed on a MacBook (CPU/MPS): ~1 s per piece outline from a point, ~8 s per piece
  location; full-photo automatic detection ~3–4 min.

## iOS implementation
- `Vision/SAMSegmenter.swift` — Core ML SAM 2.1 small (`apple/coreml-sam2.1-small`, downloaded by
  `scripts/download_sam_models.sh`): image encoder once per 1024 px tile, prompt encoder + mask
  decoder per point (~10 ms).
- `Vision/PieceDetector.swift` — prompt grid, shape filters, assembled-area exclusion, duplicates;
  also single-point segmentation for "add a missed piece".
- `Vision/ReferenceMatcher.swift` + `Matching.metal` — GPU masked Lab correlation, coarse
  (cell = 16 px) and fine (cell = 40 px) levels; scale = grid cell / √(piece area) × {0.75…1.3}, then
  narrowed to the scale learned from the first confident match on the same photo.
- `Vision/PuzzleEngine.swift` — background queue, caches models, reference textures, photos.

## Consequences
- Adds an ML dependency (SAM). On-device iOS needs a Core ML SAM 2.1 tiny/small model
  (~40–80 MB); this replaces the "classical segmentation" line in ADR 0002.
- Automatic detection on a cluttered photo finds most but not all pieces; photographing
  pieces apart on a plain background still improves recall a lot, but is not required.
- The weakest link is now matching low-detail pieces, not segmentation (see ADR 0003).
