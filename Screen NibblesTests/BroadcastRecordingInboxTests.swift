import XCTest
@testable import Screen_Nibbles

final class BroadcastRecordingInboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BroadcastRecordingInboxTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testOnlyFinalizedNonEmptyMoviesAreReturned() throws {
        let finalized = root.appendingPathComponent("a.capture", isDirectory: true)
        let partialSession = root.appendingPathComponent("b.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: finalized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partialSession, withIntermediateDirectories: true)

        let good = finalized.appendingPathComponent("0001.mov")
        try Data([1, 2, 3]).write(to: good)
        try Data().write(to: finalized.appendingPathComponent("0002.mov"))
        try Data([4]).write(to: finalized.appendingPathComponent("0003.partial.mov"))
        try Data([5]).write(to: partialSession.appendingPathComponent("0001.mov"))

        XCTAssertEqual(BroadcastRecordingInbox.readyRecordings(in: root), [good])
    }

    func testHandledMoviesAreExcluded() throws {
        let session = root.appendingPathComponent("session.capture", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let first = session.appendingPathComponent("0001.mov")
        let second = session.appendingPathComponent("0002.mov")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)

        XCTAssertEqual(
            BroadcastRecordingInbox.readyRecordings(in: root, excluding: [first]),
            [second]
        )
    }

    func testStalePartialSessionsAreCleanedWithoutTouchingRecentOnes() throws {
        let stale = root.appendingPathComponent("stale.partial", isDirectory: true)
        let recent = root.appendingPathComponent("recent.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)

        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale.path)

        BroadcastRecordingInbox.removeStalePartialSessions(
            in: root,
            olderThan: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testSequentialSegmentNamesProvideStableOrder() throws {
        let session = root.appendingPathComponent("session.capture", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let second = session.appendingPathComponent("0002.mov")
        let first = session.appendingPathComponent("0001.mov")
        try Data([2]).write(to: second)
        try Data([1]).write(to: first)

        let results = BroadcastRecordingInbox.readyRecordings(in: root)
        XCTAssertEqual(results.map(\.lastPathComponent), ["0001.mov", "0002.mov"])
    }
}
