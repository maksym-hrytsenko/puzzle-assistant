import SwiftUI
import SwiftData

struct MatchResultsView: View {
    let puzzle: Puzzle
    let capture: PieceCapture

    private var candidates: [PieceCandidate] {
        capture.pieceCandidates.sorted { lhs, rhs in
            (lhs.matches.map(\.confidence).max() ?? 0) > (rhs.matches.map(\.confidence).max() ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions are approximate — always verify visually before placing a piece.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 16) {
                    ForEach(candidates, id: \.id) { candidate in
                        CandidateCard(puzzle: puzzle, candidate: candidate)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("Suggestions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CandidateCard: View {
    let puzzle: Puzzle
    let candidate: PieceCandidate

    private var bestMatch: MatchCandidate? {
        candidate.matches.max(by: { $0.confidence < $1.confidence })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = ImageStore.shared.load(relativePath: candidate.thumbnailPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ReferenceOverlayThumbnail(puzzle: puzzle, matches: candidate.matches)
                .frame(maxHeight: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let bestMatch {
                ConfidenceBar(confidence: bestMatch.confidence)
            } else {
                Text("No confident match found").font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                statusLabel
                Spacer()
                if candidate.status != .placed {
                    Button("Mark Placed") { candidate.status = .placed }
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusLabel: some View {
        Group {
            switch candidate.status {
            case .placed:
                Label("Placed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .lowConfidence:
                Label("Needs review", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            case .unplaced:
                Label("Unplaced", systemImage: "circle")
            }
        }
        .font(.caption2)
    }
}

private struct ConfidenceBar: View {
    let confidence: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: geo.size.width * confidence)
                }
            }
            .frame(height: 6)
            Text("\(Int(confidence * 100))% confidence")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        if confidence >= 0.6 { return .green }
        if confidence >= 0.35 { return .orange }
        return .red
    }
}

private struct ReferenceOverlayThumbnail: View {
    let puzzle: Puzzle
    let matches: [MatchCandidate]

    private var referenceAspectRatio: CGFloat {
        puzzle.referenceImageHeight > 0 ? CGFloat(puzzle.referenceImageWidth) / CGFloat(puzzle.referenceImageHeight) : 1
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let path = puzzle.referenceImagePath, let image = ImageStore.shared.load(relativePath: path) {
                    Image(uiImage: image).resizable()
                } else {
                    Rectangle().fill(.secondary.opacity(0.15))
                }
                ForEach(matches, id: \.id) { match in
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.1 + 0.2 * match.confidence))
                        .frame(width: geo.size.width * match.normalizedWidth, height: geo.size.height * match.normalizedHeight)
                        .offset(x: geo.size.width * match.normalizedX, y: geo.size.height * match.normalizedY)
                }
            }
        }
        .aspectRatio(referenceAspectRatio, contentMode: .fit)
    }
}
