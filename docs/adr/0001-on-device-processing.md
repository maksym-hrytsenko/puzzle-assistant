# ADR 0001: On-device processing for MVP

## Status
Accepted

## Context
The app segments puzzle pieces from photos, corrects the reference image's perspective/color, and matches pieces against a reference image at ~4000-piece scale. The matching step is dominated by comparing feature vectors, not by heavy real-time inference — the expensive part (computing embeddings for the reference image) happens once, when the reference map is created.

## Decision
For the MVP, all computer vision and matching runs entirely on-device (iPhone), with no backend server. Storage is local only (structured metadata + image files on disk).

## Consequences
- User photos never leave the device by default — simpler privacy story, works offline (relevant since puzzle assembly often happens without reliable Wi-Fi).
- No server infrastructure, authentication, or hosting cost for MVP.
- Matching quality is bounded by what's available on-device (primarily the Vision framework). If accuracy proves insufficient, revisit and consider offloading matching to a server-side model.
- Multi-device sync is out of scope for MVP. CloudKit + SwiftData is the natural upgrade path later without a redesign.
