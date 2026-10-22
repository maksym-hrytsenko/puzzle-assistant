import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    /// A shared puzzle: `.puzzlemate` file (declared in Info.plist).
    static let puzzleArchive = UTType(exportedAs: "com.mgricenko.puzzlemate.archive")
}

enum PuzzleArchiveError: LocalizedError {
    case notAPuzzleFile
    case damaged

    var errorDescription: String? {
        switch self {
        case .notAPuzzleFile: return String(localized: "Це не файл пазла Puzzle Mate.")
        case .damaged: return String(localized: "Файл пазла пошкоджений.")
        }
    }
}

/// One file with everything about a puzzle, for sharing between phones without
/// a server: "PZMT1\n", UInt64 manifest length, manifest JSON, then the images
/// back to back. Importing merges into an existing copy of the same puzzle.
enum PuzzleArchive {
    private static let magic = Data("PZMT1\n".utf8)

    struct Manifest: Codable {
        var puzzle: PuzzleRecord
        var zones: [ZoneRecord]
        var captures: [CaptureRecord]
        var files: [FileRecord]
    }

    struct PuzzleRecord: Codable {
        var id: UUID
        var name: String
        var createdAt: Date
        var referenceImagePath: String
        var referenceThumbnailPath: String
        var referenceWidth: Int
        var referenceHeight: Int
        var pieceCount: Int
        var gridColumns: Int
        var gridRows: Int
    }

    struct ZoneRecord: Codable {
        var id: UUID
        var label: String
        var rect: CGRect
        var createdAt: Date
    }

    struct CaptureRecord: Codable {
        var id: UUID
        var photoPath: String
        var thumbnailPath: String?
        var capturedAt: Date
        var zoneID: UUID?
        var colorStatsData: Data?
        var scaleHint: Double?
        var typicalPieceArea: Double?
        var detectionFinished: Bool
        var pieces: [PieceRecord]
    }

    struct PieceRecord: Codable {
        var id: UUID
        var contourData: Data
        var area: Double
        var samScore: Double
        var isPlaced: Bool
        var placementsData: Data?
    }

    struct FileRecord: Codable {
        var path: String
        var offset: UInt64
        var length: UInt64
    }

    struct ImportSummary {
        var puzzleName: String
        var isNew: Bool
        var newCaptures: Int
        var newZones: Int
        var newlyPlaced: Int
    }

    // MARK: - Export

    @MainActor
    static func manifest(for puzzle: Puzzle) -> Manifest {
        Manifest(
            puzzle: PuzzleRecord(id: puzzle.id, name: puzzle.name, createdAt: puzzle.createdAt,
                                 referenceImagePath: puzzle.referenceImagePath,
                                 referenceThumbnailPath: puzzle.referenceThumbnailPath,
                                 referenceWidth: puzzle.referenceWidth, referenceHeight: puzzle.referenceHeight,
                                 pieceCount: puzzle.pieceCount, gridColumns: puzzle.gridColumns, gridRows: puzzle.gridRows),
            zones: puzzle.zones.map { ZoneRecord(id: $0.id, label: $0.label, rect: $0.rect, createdAt: $0.createdAt) },
            captures: puzzle.captures.map { capture in
                CaptureRecord(id: capture.id, photoPath: capture.photoPath, thumbnailPath: capture.thumbnailPath,
                              capturedAt: capture.capturedAt, zoneID: capture.zoneID, colorStatsData: capture.colorStatsData,
                              scaleHint: capture.scaleHint, typicalPieceArea: capture.typicalPieceArea,
                              detectionFinished: capture.detectionFinished,
                              pieces: capture.pieces.map {
                                  PieceRecord(id: $0.id, contourData: $0.contourData, area: $0.area, samScore: $0.samScore,
                                              isPlaced: $0.isPlaced, placementsData: $0.placementsData)
                              })
            },
            files: [])
    }

    /// Writes the archive into a temporary file (off the main thread).
    static func write(_ manifest: Manifest) throws -> URL {
        var manifest = manifest
        let paths = [manifest.puzzle.referenceImagePath, manifest.puzzle.referenceThumbnailPath]
            + manifest.captures.flatMap { [$0.photoPath] + ($0.thumbnailPath.map { [$0] } ?? []) }
        var offset: UInt64 = 0
        var present: [(String, URL)] = []
        for path in paths {
            let url = ImageStore.shared.url(path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64 else { continue }
            manifest.files.append(FileRecord(path: path, offset: offset, length: size))
            present.append((path, url))
            offset += size
        }
        let json = try JSONEncoder().encode(manifest)
        let safeName = manifest.puzzle.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).puzzlemate")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var length = UInt64(json.count).bigEndian
        try handle.write(contentsOf: magic)
        try handle.write(contentsOf: Data(bytes: &length, count: 8))
        try handle.write(contentsOf: json)
        for (_, fileURL) in present {
            try handle.write(contentsOf: try Data(contentsOf: fileURL, options: .mappedIfSafe))
        }
        return url
    }

    // MARK: - Import

    /// Reads the manifest and copies missing images (off the main thread).
    static func read(_ url: URL) throws -> Manifest {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: magic.count) == magic,
              let lengthData = try handle.read(upToCount: 8), lengthData.count == 8 else {
            throw PuzzleArchiveError.notAPuzzleFile
        }
        let length = lengthData.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length < 200_000_000, let json = try handle.read(upToCount: Int(length)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: json) else {
            throw PuzzleArchiveError.damaged
        }
        let dataStart = UInt64(magic.count + 8) + length
        for file in manifest.files {
            // Paths must stay inside this puzzle's folder.
            guard file.path.hasPrefix(manifest.puzzle.id.uuidString + "/"), !file.path.contains("..") else {
                throw PuzzleArchiveError.damaged
            }
            let target = ImageStore.shared.url(file.path)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try handle.seek(toOffset: dataStart + file.offset)
            guard let data = try handle.read(upToCount: Int(file.length)), UInt64(data.count) == file.length else {
                throw PuzzleArchiveError.damaged
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        return manifest
    }

    /// Adds the shared puzzle, or merges it into the existing copy: new zones,
    /// photos and pieces are added; a piece placed on either phone stays placed.
    @MainActor
    static func merge(_ manifest: Manifest, into context: ModelContext) throws -> ImportSummary {
        let id = manifest.puzzle.id
        let existing = try context.fetch(FetchDescriptor<Puzzle>(predicate: #Predicate { $0.id == id })).first
        let puzzle: Puzzle
        if let existing {
            puzzle = existing
        } else {
            let p = manifest.puzzle
            puzzle = Puzzle(id: p.id, name: p.name, referenceImagePath: p.referenceImagePath,
                            referenceThumbnailPath: p.referenceThumbnailPath, referenceWidth: p.referenceWidth,
                            referenceHeight: p.referenceHeight, pieceCount: p.pieceCount)
            puzzle.createdAt = p.createdAt
            puzzle.gridColumns = p.gridColumns
            puzzle.gridRows = p.gridRows
            context.insert(puzzle)
        }
        var summary = ImportSummary(puzzleName: puzzle.name, isNew: existing == nil, newCaptures: 0, newZones: 0, newlyPlaced: 0)

        let zoneIDs = Set(puzzle.zones.map(\.id))
        for record in manifest.zones where !zoneIDs.contains(record.id) {
            let zone = PuzzleZone(label: record.label, rect: record.rect)
            zone.id = record.id
            zone.createdAt = record.createdAt
            context.insert(zone)
            zone.puzzle = puzzle
            summary.newZones += 1
        }

        for record in manifest.captures {
            let capture: PieceCapture
            if let found = puzzle.captures.first(where: { $0.id == record.id }) {
                capture = found
            } else {
                capture = PieceCapture(photoPath: record.photoPath, zoneID: record.zoneID)
                capture.id = record.id
                capture.capturedAt = record.capturedAt
                capture.thumbnailPath = record.thumbnailPath
                capture.colorStatsData = record.colorStatsData
                capture.scaleHint = record.scaleHint
                capture.typicalPieceArea = record.typicalPieceArea
                capture.detectionFinished = record.detectionFinished
                context.insert(capture)
                capture.puzzle = puzzle
                summary.newCaptures += 1
            }
            var pieces = Dictionary(uniqueKeysWithValues: capture.pieces.map { ($0.id, $0) })
            for p in record.pieces {
                if let piece = pieces[p.id] {
                    if p.isPlaced && !piece.isPlaced {
                        piece.isPlaced = true
                        summary.newlyPlaced += 1
                    }
                    if piece.placementsData == nil { piece.placementsData = p.placementsData }
                } else {
                    let piece = DetectedPiece(outline: DetectedOutline(contour: [], area: p.area, score: p.samScore))
                    piece.id = p.id
                    piece.contourData = p.contourData
                    piece.isPlaced = p.isPlaced
                    piece.placementsData = p.placementsData
                    context.insert(piece)
                    piece.capture = capture
                    pieces[p.id] = piece
                    if p.isPlaced { summary.newlyPlaced += 1 }
                }
            }
        }
        return summary
    }
}
