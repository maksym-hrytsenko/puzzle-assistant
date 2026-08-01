# Puzzle Assistant

An iOS app that helps a person assemble a large physical jigsaw puzzle (~4000 pieces) by suggesting probable locations for individual pieces on a reference image, along with a confidence level. It does not assemble the puzzle and does not guarantee correct placement — it narrows the search space and requires the user's visual confirmation.

## Status

Planning phase complete. No application code exists yet. See `docs/adr/` for the architecture decisions made so far and the iterative build plan agreed with the project owner.

## Core scenarios

- **Reference map creation** — photograph the puzzle box/reference image; the app detects its boundaries, corrects perspective, crops, and adjusts color/contrast/sharpness.
- **Piece recognition** — photograph loose pieces; the app segments them, accounts for rotation, and returns ranked candidate locations on the reference image with confidence scores.
- **Zone mode** — the user selects a region of the reference image; the app restricts matching to that region and honestly reports when no photographed piece appears to belong to it.
- **Progress tracking** — mark pieces as placed, review low-confidence matches, see per-zone completion and capture history.

## Build & run

Not available yet — no Xcode project has been created. This section will be updated once a buildable app skeleton exists.

## Architecture

See `docs/adr/` for recorded decisions, starting with on-device vs. server processing and the technology stack.

## Honesty note

Matching a puzzle piece to its location on a reference image is a computer vision problem with real, fundamental limits — especially for low-detail regions (sky, water, plain textures). The app is designed to always show its confidence level and never claim certainty it doesn't have.
