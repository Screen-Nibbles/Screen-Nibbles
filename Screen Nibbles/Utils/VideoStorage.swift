import Foundation

/// Owns durable copies of imported recordings and hides transient file-provider/broadcast races.
enum VideoStorage {
    enum StorageError: LocalizedError {
        case sourceMissing
        case sourceEmpty
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "The recording is no longer available. Choose it again or make a new recording."
            case .sourceEmpty:
                return "The recording did not finish writing. Try importing it again."
            case .copyFailed:
                return "The recording could not be copied into Screen Nibbles."
            }
        }
    }

    static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func existingURL(for filename: String) -> URL? {
        let modern = directory.appendingPathComponent(filename)
        if isUsableFile(modern) { return modern }

        // Older builds stored recordings directly in Documents. Keep reading them
        // without forcing a migration at app launch.
        let legacy = URL.documentsDirectory.appendingPathComponent(filename)
        if isUsableFile(legacy) { return legacy }
        return nil
    }

    static func isUsableFile(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else { return false }
        return true
    }

    /// Makes a same-volume, verified copy before returning its final URL. Copying
    /// through a temporary name means SwiftData never points at a half-written file.
    static func copyToLibrary(from sourceURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw StorageError.sourceMissing }
        guard isUsableFile(sourceURL) else { throw StorageError.sourceEmpty }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let filename = "video_\(UUID().uuidString).\(ext)"
        let finalURL = directory.appendingPathComponent(filename)
        let partialURL = directory.appendingPathComponent(".\(filename).partial")

        do {
            try? FileManager.default.removeItem(at: partialURL)
            try FileManager.default.copyItem(at: sourceURL, to: partialURL)
            guard isUsableFile(partialURL) else {
                try? FileManager.default.removeItem(at: partialURL)
                throw StorageError.sourceEmpty
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            return finalURL
        } catch let error as StorageError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw StorageError.copyFailed
        }
    }
}
