# ADR 0002: iOS technology stack

## Status
Accepted

## Context
The MVP needs a language/UI framework and a computer vision / ML approach, with fast iteration and no existing training data for custom models.

## Decision
- **Language/UI:** Swift + SwiftUI, targeting iOS 17+ (enables SwiftData and current Vision APIs).
- **Capture:** AVFoundation with custom camera control, rather than a stock image picker, for consistent exposure/focus across piece photos.
- **Perspective/boundary detection:** `VNDetectRectanglesRequest` + `CIPerspectiveCorrection`.
- **Color/contrast/sharpness correction:** built-in Core Image filters.
- **Piece segmentation:** classical CV via Vision/vImage against a plain, contrasting background (the app will recommend this to the user), rather than a custom-trained segmentation model — no training data exists yet to justify one.
- **Matching:** `VNGenerateImageFeaturePrintRequest` for feature embeddings and its built-in distance computation, avoiding the need to train a custom model for MVP.
- **OpenCV:** kept as an optional fallback dependency if Vision/Core Image prove insufficient for a specific step — not adopted by default.
- **Persistence:** SwiftData for structured metadata (puzzles, zones, pieces, confidence, history); image files and thumbnails stored on disk and referenced by path.

## Consequences
- Fast path to a working MVP using mature, Apple-maintained APIs with no upfront model training.
- Matching accuracy for low-detail image regions remains a fundamental limitation regardless of stack choice — not something this decision can fix.
- Custom ML segmentation/matching models remain a documented option for later, once real usage data exists to train on.
