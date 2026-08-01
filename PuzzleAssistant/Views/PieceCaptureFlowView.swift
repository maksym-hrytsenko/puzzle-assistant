import SwiftUI
import SwiftData

struct PieceCaptureFlowView: View {
    let puzzle: Puzzle
    let restrictedToZone: Zone?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Stage: Equatable {
        case waitingForPhoto
        case processing(String)
        case reviewing(PersistentIdentifier)
        case noPiecesFound
        case failed(String)
    }

    @State private var isPresentingCamera = true
    @State private var stage: Stage = .waitingForPhoto

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .waitingForPhoto:
                    Color.black.ignoresSafeArea()
                case .processing(let message):
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(message).foregroundStyle(.secondary)
                    }
                case .reviewing(let captureID):
                    if let capture = modelContext.model(for: captureID) as? PieceCapture {
                        MatchResultsView(puzzle: puzzle, capture: capture)
                    } else {
                        ContentUnavailableView("Capture unavailable", systemImage: "exclamationmark.triangle")
                    }
                case .noPiecesFound:
                    ContentUnavailableView(
                        "No pieces found in this batch",
                        systemImage: "questionmark.square.dashed",
                        description: Text(restrictedToZone != nil
                            ? "None of the photographed pieces looked like a confident match for the \"\(restrictedToZone!.label)\" zone. Try photographing the next group of pieces."
                            : "The app couldn't confidently separate any pieces from the background in this photo. Try a plainer, more contrasting surface and even lighting.")
                    )
                case .failed(let message):
                    ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if stage == .noPiecesFound {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Try Another Photo") { isPresentingCamera = true; stage = .waitingForPhoto }
                    }
                }
            }
            .fullScreenCover(isPresented: $isPresentingCamera) {
                CameraCaptureView(instructions: "Lay pieces flat, not touching, on a plain contrasting surface.") { image in
                    process(image)
                }
            }
        }
    }

    private func process(_ image: UIImage) {
        stage = .processing("Finding pieces…")
        Task {
            do {
                let detected = try PieceSegmenter.segmentPieces(in: image)

                let capture = PieceCapture(photoPath: try ImageStore.shared.save(image, named: "capture-\(UUID().uuidString).jpg", in: puzzle.id, quality: 0.8))
                capture.puzzle = puzzle
                modelContext.insert(capture)

                for piece in detected {
                    let pieceImage = UIImage(cgImage: piece.croppedImage)
                    let croppedPath = try ImageStore.shared.save(pieceImage, named: "\(UUID().uuidString).jpg", in: puzzle.id)
                    let thumbnail = ImageStore.shared.makeThumbnail(of: pieceImage)
                    let thumbnailPath = try ImageStore.shared.save(thumbnail, named: "\(UUID().uuidString)_thumb.jpg", in: puzzle.id)

                    let candidate = PieceCandidate(
                        croppedImagePath: croppedPath,
                        thumbnailPath: thumbnailPath,
                        boundingBox: piece.normalizedBoundingBox,
                        estimatedRotationDegrees: piece.estimatedRotationDegrees
                    )
                    candidate.capture = capture
                    modelContext.insert(candidate)
                }

                let captureEvent = SessionEvent(kind: .piecesCaptured, summary: "Captured \(detected.count) piece(s)\(restrictedToZone.map { " for zone \"\($0.label)\"" } ?? "").")
                captureEvent.puzzle = puzzle
                modelContext.insert(captureEvent)

                stage = .processing("Comparing against the reference map…")
                try await runMatching(for: capture)

                if restrictedToZone != nil && !hasConfidentZoneMatch(in: capture) {
                    stage = .noPiecesFound
                } else {
                    stage = .reviewing(capture.persistentModelID)
                }
            } catch PieceSegmenterError.noPiecesDetected {
                stage = .noPiecesFound
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func runMatching(for capture: PieceCapture) async throws {
        guard let referencePath = puzzle.referenceImagePath,
              let referenceImage = ImageStore.shared.load(relativePath: referencePath) else { return }

        let index = ReferenceIndex()
        try index.build(from: referenceImage)

        for candidate in capture.pieceCandidates {
            guard let pieceImage = ImageStore.shared.load(relativePath: candidate.croppedImagePath)?.cgImage else { continue }
            let matches = index.topMatches(for: pieceImage, restrictedTo: restrictedToZone?.normalizedRect)
            candidate.applyMatches(matches)
        }

        let matchEvent = SessionEvent(kind: .matchRunCompleted, summary: "Matched \(capture.pieceCandidates.count) piece(s) against the reference map.")
        matchEvent.puzzle = puzzle
        modelContext.insert(matchEvent)
    }

    private func hasConfidentZoneMatch(in capture: PieceCapture) -> Bool {
        capture.pieceCandidates.contains { candidate in
            candidate.matches.contains { $0.confidence >= 0.5 }
        }
    }
}
