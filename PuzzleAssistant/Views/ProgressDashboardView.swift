import SwiftUI
import SwiftData

struct ProgressDashboardView: View {
    let puzzle: Puzzle

    private var allCandidates: [PieceCandidate] {
        puzzle.pieceCaptures.flatMap(\.pieceCandidates)
    }

    private var events: [SessionEvent] {
        puzzle.sessionEvents.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Detected pieces", value: "\(allCandidates.count)")
                LabeledContent("Placed", value: "\(allCandidates.filter { $0.status == .placed }.count)")
                LabeledContent("Needs review (low confidence)", value: "\(allCandidates.filter { $0.status == .lowConfidence }.count)")
                LabeledContent("Unplaced", value: "\(allCandidates.filter { $0.status == .unplaced }.count)")
            }

            if !puzzle.zones.isEmpty {
                Section("Zones") {
                    ForEach(puzzle.zones.sorted(by: { $0.createdAt < $1.createdAt }), id: \.id) { zone in
                        HStack {
                            Text(zone.label)
                            Spacer()
                            Text(zone.status.displayName).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("History") {
                if events.isEmpty {
                    Text("No activity yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(events, id: \.id) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.summary)
                            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
    }
}
