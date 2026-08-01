import SwiftUI
import SwiftData

struct PuzzleDetailView: View {
    let puzzle: Puzzle

    @State private var isPresentingPieceCapture = false
    @State private var isPresentingZoneSelection = false
    @State private var pendingZoneRestriction: Zone?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                referenceImageView

                ProgressSummaryView(puzzle: puzzle)

                VStack(spacing: 12) {
                    Button {
                        pendingZoneRestriction = nil
                        isPresentingPieceCapture = true
                    } label: {
                        Label("Capture Pieces", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        isPresentingZoneSelection = true
                    } label: {
                        Label("Define a Zone", systemImage: "rectangle.dashed.badge.record")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    NavigationLink {
                        ProgressDashboardView(puzzle: puzzle)
                    } label: {
                        Label("Progress & History", systemImage: "chart.bar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                if !puzzle.zones.isEmpty {
                    zonesSection
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(puzzle.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isPresentingPieceCapture) {
            PieceCaptureFlowView(puzzle: puzzle, restrictedToZone: pendingZoneRestriction)
        }
        .sheet(isPresented: $isPresentingZoneSelection) {
            ZoneSelectionView(puzzle: puzzle)
        }
    }

    @ViewBuilder
    private var referenceImageView: some View {
        if let path = puzzle.referenceImagePath, let image = ImageStore.shared.load(relativePath: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
        }
    }

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zones").font(.headline).padding(.horizontal)
            ForEach(puzzle.zones.sorted(by: { $0.createdAt < $1.createdAt }), id: \.id) { zone in
                Button {
                    pendingZoneRestriction = zone
                    isPresentingPieceCapture = true
                } label: {
                    HStack {
                        Text(zone.label)
                        Spacer()
                        Text(zone.status.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProgressSummaryView: View {
    let puzzle: Puzzle

    private var allCandidates: [PieceCandidate] {
        puzzle.pieceCaptures.flatMap(\.pieceCandidates)
    }

    var body: some View {
        HStack(spacing: 16) {
            StatTile(title: "Detected", value: allCandidates.count)
            StatTile(title: "Placed", value: allCandidates.filter { $0.status == .placed }.count)
            StatTile(title: "Needs review", value: allCandidates.filter { $0.status == .lowConfidence }.count)
        }
        .padding(.horizontal)
    }
}

private struct StatTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack {
            Text("\(value)").font(.title2).bold()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension ZoneStatus {
    var displayName: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .done: return "Done"
        }
    }
}
