import Foundation

/// Discovers only finalized ReplayKit recordings. The extension writes into a
/// `.partial` directory and atomically renames the directory to `.capture` only
/// after AVAssetWriter has finished, so the app never intentionally opens a
/// live movie.
enum BroadcastRecordingInbox {
    static let groupID = "group.com.tomaslin.Screen-Nibbles"

    static func sharedRecordingsDirectory(fileManager: FileManager = .default) -> URL? {
        #if canImport(Darwin)
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Recordings", isDirectory: true)
        #else
        return nil
        #endif
    }

    /// Removes abandoned in-progress sessions from previous extension crashes.
    /// A generous age threshold ensures an active or recently interrupted
    /// broadcast is never touched.
    static func removeStalePartialSessions(
        in directory: URL,
        olderThan cutoff: Date,
        fileManager: FileManager = .default
    ) {
        let sessions = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for session in sessions where session.pathExtension == "partial" {
            guard let values = try? session.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
            ), values.isDirectory == true else { continue }
            let lastTouched = values.contentModificationDate ?? values.creationDate ?? .distantFuture
            guard lastTouched < cutoff else { continue }
            try? fileManager.removeItem(at: session)
        }
    }

    static func readyRecordings(
        in directory: URL,
        excluding handled: Set<URL> = [],
        fileManager: FileManager = .default
    ) -> [URL] {
        let sessions = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let captureSessions = sessions.filter { url in
            guard url.pathExtension == "capture" else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var candidates: [(url: URL, sessionDate: Date, fileDate: Date, segmentIndex: Int?)] = []
        for session in captureSessions {
            let sessionDate = (try? session.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let files = (try? fileManager.contentsOfDirectory(
                at: session,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension.lowercased() == "mov" && !handled.contains(file) {
                guard !file.lastPathComponent.contains(".partial."),
                      let values = try? file.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      (values.fileSize ?? 0) > 0 else { continue }
                let segmentIndex = Int(file.deletingPathExtension().lastPathComponent)
                candidates.append((file, sessionDate, values.creationDate ?? sessionDate, segmentIndex))
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.sessionDate != rhs.sessionDate { return lhs.sessionDate < rhs.sessionDate }
            if let leftIndex = lhs.segmentIndex, let rightIndex = rhs.segmentIndex, leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            if lhs.fileDate != rhs.fileDate { return lhs.fileDate < rhs.fileDate }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }.map(\.url)
    }
}
