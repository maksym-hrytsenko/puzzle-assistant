import Foundation
import UIKit

enum ImageStoreError: Error {
    case encodingFailed
    case writeFailed
}

struct ImageStore {
    static let shared = ImageStore()

    private var baseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Puzzles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func directory(for puzzleID: UUID) -> URL {
        let dir = baseDirectory.appendingPathComponent(puzzleID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func save(_ image: UIImage, named name: String, in puzzleID: UUID, quality: CGFloat = 0.9) throws -> String {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw ImageStoreError.encodingFailed
        }
        let fileURL = directory(for: puzzleID).appendingPathComponent(name)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ImageStoreError.writeFailed
        }
        return "\(puzzleID.uuidString)/\(name)"
    }

    func makeThumbnail(of image: UIImage, maxDimension: CGFloat = 240) -> UIImage {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    func load(relativePath: String) -> UIImage? {
        UIImage(contentsOfFile: url(relativePath).path)
    }

    func url(_ relativePath: String) -> URL {
        baseDirectory.appendingPathComponent(relativePath)
    }

    func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: url(relativePath))
    }

    func deleteAll(for puzzleID: UUID) {
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(puzzleID.uuidString, isDirectory: true))
    }
}
