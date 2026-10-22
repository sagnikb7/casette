import XCTest
@testable import OfflineMusicPlayer

final class LibraryTests: XCTestCase {
    @MainActor
    func testPersistedDirectoryCheckSkipsFiveHundredSongsAndDetectsNestedAddition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Files"), album = docs.appendingPathComponent("Album")
        let store = root.appendingPathComponent("Index.sqlite")
        let library = LibraryStore(documents: docs, databaseURL: store)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        for index in 0..<500 { try FileManager.default.copyItem(at: fixture, to: album.appendingPathComponent("Song\(index).wav")) }
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.tracks.count, 500)
        XCTAssertEqual(try library.database?.all("scanCheckpoint", as: ScanCheckpoint.self).count, 1)
        let reopened = LibraryStore(documents: docs, databaseURL: store)
        reopened.discoverChangesOnLaunch(); try await waitForDiscovery(reopened)
        XCTAssertEqual(reopened.scanRunCount, 0, "Unchanged restart must not enumerate audio")
        XCTAssertEqual(reopened.scannedCount, 0)
        XCTAssertEqual(reopened.tracks.count, 500)
        try FileManager.default.copyItem(at: fixture, to: album.appendingPathComponent("Added.wav"))
        let changed = LibraryStore(documents: docs, databaseURL: store)
        changed.discoverChangesOnLaunch(); try await waitForDiscovery(changed)
        XCTAssertEqual(changed.scanRunCount, 1, "Nested folder changes must be detected")
        XCTAssertEqual(changed.tracks.count, 501)
        changed.discoverChangesOnLaunch(); try await waitForDiscovery(changed)
        XCTAssertEqual(changed.scanRunCount, 1, "Repeated view appearance cannot rescan")
    }

    @MainActor
    func testProviderSourceIsNotProbedOnLaunchAndManualRescanFindsChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Files"), external = root.appendingPathComponent("External"), store = root.appendingPathComponent("Index.sqlite")
        let library = LibraryStore(documents: docs, databaseURL: store)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: external.appendingPathComponent("First.wav"))
        library.addFolder(external); try await waitForScan(library)
        library.rescan(); try await waitForScan(library)
        let source = try XCTUnwrap(library.sources.first { !$0.isOwned })
        try FileManager.default.copyItem(at: fixture, to: external.appendingPathComponent("Second.wav"))
        let reopened = LibraryStore(documents: docs, databaseURL: store)
        reopened.discoverChangesOnLaunch(); try await waitForDiscovery(reopened)
        XCTAssertEqual(reopened.scanRunCount, 0)
        XCTAssertEqual(reopened.tracks.count, 1)
        reopened.rescan(only: source.id); try await waitForScan(reopened)
        XCTAssertEqual(reopened.tracks.count, 2)
    }

    @MainActor
    func testAutomaticDiscoveryDefersForPlaybackAndHonorsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(documents: root, inMemory: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        library.setPlaybackActive(true)
        library.discoverChangesOnLaunch(); try await waitForDiscovery(library)
        XCTAssertEqual(library.scanRunCount, 0)
        library.setPlaybackActive(false); try await waitForScan(library)
        XCTAssertEqual(library.scanRunCount, 1); XCTAssertEqual(library.tracks.count, 1)
        let cancelled = LibraryStore(documents: root, inMemory: true)
        cancelled.setPlaybackActive(true); cancelled.discoverChangesOnLaunch(); try await waitForDiscovery(cancelled)
        cancelled.cancelScan(); cancelled.setPlaybackActive(false)
        XCTAssertFalse(cancelled.scanning); XCTAssertEqual(cancelled.scanRunCount, 0)
        let background = LibraryStore(documents: root, inMemory: true)
        background.setSceneActive(false); background.discoverChangesOnLaunch(); try await waitForDiscovery(background)
        XCTAssertEqual(background.scanRunCount, 0)
        background.setSceneActive(true); try await waitForScan(background)
        XCTAssertEqual(background.tracks.count, 1)
    }

    @MainActor
    func testCancelledScanDoesNotAdvanceCheckpointAndInPlaceLyricsNeedManualRescan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Files"), store = root.appendingPathComponent("Index.sqlite")
        let library = LibraryStore(documents: docs, databaseURL: store)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: docs.appendingPathComponent("Song.wav"))
        let lyrics = docs.appendingPathComponent("Song.lrc")
        try Data("first".utf8).write(to: lyrics)
        library.rescan(); try await waitForScan(library)
        let checkpoint = try XCTUnwrap(library.database?.all("scanCheckpoint", as: ScanCheckpoint.self).first)
        // Write in place, preserving the directory's timestamp: metadata-only edits are explicit.
        let folderDate = try XCTUnwrap(docs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let handle = try FileHandle(forWritingTo: lyrics)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("second lyric".utf8)); try handle.close()
        XCTAssertEqual(try docs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, folderDate)
        let reopened = LibraryStore(documents: docs, databaseURL: store)
        reopened.discoverChangesOnLaunch(); try await waitForDiscovery(reopened)
        XCTAssertEqual(reopened.scanRunCount, 0)
        XCTAssertEqual(reopened.tracks.first?.lyrics, "first")
        reopened.rescan(); reopened.cancelScan(); try await waitForScan(reopened)
        XCTAssertEqual(try reopened.database?.all("scanCheckpoint", as: ScanCheckpoint.self).first?.directories, checkpoint.directories)
        reopened.rescan(); try await waitForScan(reopened)
        XCTAssertEqual(reopened.tracks.first?.lyrics, "second lyric")
    }

    func testFiveHundredUnchangedFilesDoNotPublishTrackBatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        for index in 0..<500 { try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song\(index).wav")) }
        let scanner = LibraryScanner(), source = UUID()
        let first = try await scanner.scan(root: root, sourceID: source, existing: [:], cache: cache) { _, _ in }
        XCTAssertEqual(first.tracks.count, 500)
        let observer = ScanObserver()
        let start = ProcessInfo.processInfo.systemUptime
        let second = try await scanner.scan(root: root, sourceID: source,
            existing: Dictionary(uniqueKeysWithValues: first.tracks.map { ($0.id, $0) }), cache: cache,
            checked: { count in await observer.checked(count) }, progress: { batch, _ in await observer.batch(batch.count) })
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let counts = await observer.counts()
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.2, 500)
        XCTAssertLessThanOrEqual(counts.1, Int(elapsed / 0.25) + 2)
        XCTAssertEqual(first.tracks, second.tracks)
        XCTAssertTrue(second.complete)
    }

    @MainActor
    func testIncompleteScanPreservesMissingTracksUntilSuccessfulEnumeration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(documents: root, inMemory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        let song = root.appendingPathComponent("Song.wav")
        try FileManager.default.copyItem(at: fixture, to: song)
        library.rescan(); try await waitForScan(library)
        let id = try XCTUnwrap(library.tracks.first?.id)
        try FileManager.default.removeItem(at: song)
        let invalid = root.appendingPathComponent("Oversized.m3u")
        try Data(repeating: 0, count: 2_000_001).write(to: invalid)
        library.rescan(); try await waitForScan(library)
        XCTAssertTrue(try XCTUnwrap(library.track(id)).available)
        try FileManager.default.removeItem(at: invalid)
        library.rescan(); try await waitForScan(library)
        XCTAssertFalse(try XCTUnwrap(library.track(id)).available)
    }

    func testTimedLyricsOffsetsMultipleTimestampsAndMalformedInput() {
        let result = LRCParser.parse("[ar:Artist]\n[offset:-500]\n[00:01.25][00:03.00]Hello\n[bad]skip\n[00:99.00]invalid")
        XCTAssertEqual(result.map(\.text), ["Hello", "Hello"])
        XCTAssertEqual(result.map(\.time), [0.75, 2.5])
        XCTAssertTrue(LRCParser.parse("Plain lyrics").isEmpty)
    }
    func testSourceExclusionUsesPathBoundariesAndOldRecordsDecode() throws {
        var source = MusicSource(id: UUID(), name: "Music", isOwned: true)
        source.excludedPaths = ["Podcasts"]
        XCTAssertFalse(source.permits("Podcasts/file.mp3"))
        XCTAssertTrue(source.permits("Podcasts Plus/file.mp3"))
        XCTAssertTrue(source.permits("Albums/file.mp3"))
        source.enabled = false; XCTAssertFalse(source.permits("Albums/file.mp3"))
        let legacy = "{\"id\":\"\(source.id)\",\"name\":\"Music\",\"isOwned\":true}"
        let decoded = try JSONDecoder().decode(MusicSource.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.enabled); XCTAssertTrue(decoded.excludedPaths.isEmpty)
    }
    @MainActor
    func testLocalLibraryExclusionsFavoritesPlaylistsAndRemovalAreNonDestructive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blocked = root.appendingPathComponent("Podcasts")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        try FileManager.default.copyItem(at: fixture, to: blocked.appendingPathComponent("Talk.wav"))
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.tracks.count, 2)
        let song = try XCTUnwrap(library.tracks.first { $0.title == "Song" })
        XCTAssertEqual(song.artist, "Unknown Artist")
        library.favorite(song); library.createPlaylist("Road trip")
        var playlist = try XCTUnwrap(library.playlists.first); playlist.trackIDs = [song.id, song.id]
        library.changePlaylist(playlist)
        XCTAssertEqual(try library.database?.all("playlist", as: MusicPlaylist.self).first?.trackIDs.count, 2)
        let owned = try XCTUnwrap(library.sources.first)
        library.excludeFolder(blocked, from: owned.id); try await waitForScan(library)
        XCTAssertEqual(library.visibleTracks.count, 1)
        XCTAssertEqual(library.tracks.count, 2, "Exclusion preserves persistent track identities")
        XCTAssertTrue(library.track(song.id)?.favorite ?? false)
        library.includeFolder(owned.id, path: "Podcasts"); try await waitForScan(library)
        XCTAssertEqual(library.visibleTracks.count, 2)
        // A genuinely external folder (outside Cassette's own Documents container) becomes its own
        // removable source; a subfolder of the owned root would instead reuse the owned source (see
        // FolderPlayerRefinementTests.testOwnedSubfolderSelectionAndDisconnectedDuplicateSuppression).
        let externalFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        try FileManager.default.copyItem(at: fixture, to: externalFolder.appendingPathComponent("Extra.wav"))
        library.addFolder(externalFolder); try await waitForScan(library)
        let external = try XCTUnwrap(library.sources.first { !$0.isOwned })
        XCTAssertEqual(library.tracks.first { $0.title == "Extra" }?.locations.count, 1)
        XCTAssertEqual(library.visibleTracks.count, 3)
        library.removeSource(external)
        XCTAssertEqual(library.tracks.first { $0.title == "Extra" }?.locations.count, 0, "Removing the only source for a track drops its locations")
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFolder.appendingPathComponent("Extra.wav").path), "Removing a source must not delete the underlying file")
        XCTAssertEqual(library.visibleTracks.count, 2)
        library.setEnabled(owned.id, enabled: false); XCTAssertTrue(library.visibleTracks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("Talk.wav").path))
        library.deletePlaylist(playlist); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Song.wav").path))
    }
    func testOverlappingRootsDeduplicateIdentityButSeparateCopiesRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("Album")
        let cache = root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: child.appendingPathComponent("Song.wav"))
        try FileManager.default.copyItem(at: fixture, to: child.appendingPathComponent("Copy.wav"))
        let scanner = LibraryScanner()
        let first = try await scanner.scan(root: root, sourceID: UUID(), existing: [:], cache: cache) { _, _ in }
        let second = try await scanner.scan(root: child, sourceID: UUID(), existing: Dictionary(uniqueKeysWithValues: first.tracks.map { ($0.id, $0) }), cache: cache) { _, _ in }
        XCTAssertEqual(first.tracks.count, 2)
        XCTAssertEqual(Set(first.tracks.map(\.id)), Set(second.tracks.map(\.id)))
        XCTAssertEqual(second.tracks[0].locations.count, 2)
        let cancelled = Task { try await scanner.scan(root: root, sourceID: UUID(), existing: [:], cache: cache) { _, _ in } }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled scan completed") } catch is CancellationError { }
    }
    func testPlaybackFilePolicyRejectsEscapesAndReplacedSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside.wav")
        try Data([0]).write(to: outside)
        let local = music.appendingPathComponent("Song.wav")
        try Data([0]).write(to: local)
        XCTAssertEqual(try LocalFilePolicy.musicFile("Song.wav", in: music), local)
        XCTAssertThrowsError(try LocalFilePolicy.musicFile("../Outside.wav", in: music))
        XCTAssertThrowsError(try LocalFilePolicy.musicFile(outside.path, in: music))
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: outside)
        XCTAssertThrowsError(try LocalFilePolicy.musicFile("Song.wav", in: music))
        XCTAssertThrowsError(try LocalFilePolicy.check(local))
    }

    @MainActor
    func testDiskPersistenceAcrossStoreInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        var first: LibraryDatabase? = try LibraryDatabase(storeURL: url)
        try first?.save(MusicPlaylist(name: "Persisted"), key: "playlist:one", kind: "playlist")
        try first?.commit()
        if let first = first {
            first.container.viewContext.reset()
            for store in first.container.persistentStoreCoordinator.persistentStores { try first.container.persistentStoreCoordinator.remove(store) }
        }
        first = nil
        let reopened = try LibraryDatabase(storeURL: url)
        defer {
            reopened.container.viewContext.reset()
            for store in reopened.container.persistentStoreCoordinator.persistentStores { try? reopened.container.persistentStoreCoordinator.remove(store) }
        }
        XCTAssertEqual(try reopened.all("playlist", as: MusicPlaylist.self).first?.name, "Persisted")
    }
    @MainActor
    func testDatabaseRecordRoundTripAndDeletion() throws {
        // An isolated in-memory store verifies round-trip serialization without touching production data.
        let db = try LibraryDatabase(inMemory: true)
        let playlist = MusicPlaylist(name: "Unicode ♪ हिंदी")
        try db.save(playlist, key: "playlist:test", kind: "playlist"); try db.commit()
        XCTAssertEqual(try db.all("playlist", as: MusicPlaylist.self).first?.name, playlist.name)
        try db.remove(key: "playlist:test"); try db.commit()
        XCTAssertTrue(try db.all("playlist", as: MusicPlaylist.self).isEmpty)
    }
}

private actor ScanObserver {
    var batches = 0, updates = 0, last = 0
    func checked(_ value: Int) { updates += 1; last = value }
    func batch(_ count: Int) { batches += count }
    func counts() -> (Int, Int, Int) { (batches, updates, last) }
}

@MainActor
private func waitForDiscovery(_ library: LibraryStore) async throws {
    for _ in 0..<400 {
        if !library.checkingFolders && !library.scanning { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Discovery did not finish"); library.cancelScan()
}
