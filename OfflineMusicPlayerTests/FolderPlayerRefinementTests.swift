import XCTest
import SwiftUI
@testable import OfflineMusicPlayer

final class FolderPlayerRefinementTests: XCTestCase {
    @MainActor
    func testTransportHoldRepeatsAndStopsWithoutSkipping() async throws {
        var taps = 0, seeks = 0
        let button = SeekTransportButton(symbol: "forward.fill", label: "Next song", tap: { taps += 1 }, seek: { seeks += 1 })
        let coordinator = button.makeCoordinator()
        coordinator.beginSeeking()
        XCTAssertEqual(seeks, 1)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertGreaterThanOrEqual(seeks, 2)
        coordinator.stop()
        let stopped = seeks
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(seeks, stopped)
        XCTAssertEqual(taps, 0)
        coordinator.beginSeeking()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let inactiveCount = seeks
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(seeks, inactiveCount, "Backgrounding stops a held seek")
        coordinator.tapped()
        XCTAssertEqual(taps, 1)
        XCTAssertTrue(coordinator.accessibleSeek())
        XCTAssertEqual(seeks, inactiveCount + 1)
    }

    @MainActor
    func testRescanReportsSmallFoldersAndAccumulatesAcrossSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("App")
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let library = LibraryStore(documents: owned, inMemory: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: owned.appendingPathComponent("First.wav"))
        try FileManager.default.copyItem(at: fixture, to: external.appendingPathComponent("Second.wav"))
        library.addFolder(external); try await waitForScan(library)
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.scannedCount, 2, "Counts accumulate across sources")
        let scanner = LibraryScanner()
        actor Counts {
            var values: [Int] = []
            func append(_ count: Int) { values.append(count) }
        }
        let counts = Counts()
        _ = try await scanner.scan(root: external, sourceID: UUID(), existing: [:], cache: library.artworkDirectory, checked: { count in await counts.append(count) }, progress: { _, _ in })
        let values = await counts.values
        XCTAssertEqual(values.first, 1, "Small folders report before a 25-file batch")
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(library.visibleTracks.count, 2)
    }

    @MainActor
    func testAddingFolderDuringScanFinishesWithPersistedGrantAndNoDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("File Provider Storage/Music")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: external.appendingPathComponent("Song.wav"))
        let library = LibraryStore(documents: root.appendingPathComponent("App"), inMemory: true)
        library.rescan()
        XCTAssertTrue(library.scanning)
        library.addFolder(external)
        library.addFolder(external) // Repeated selection while the previous scan is cancelling.
        try await waitForScan(library)
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.visibleTracks.count, 1)
        let source = try XCTUnwrap(library.sources.first { !$0.isOwned })
        let saved = try XCTUnwrap(library.database?.all("source", as: MusicSource.self).first { $0.id == source.id })
        // Resolve in another store so this checks the bookmark, not a cached picker URL.
        let fresh = LibraryStore(documents: root.appendingPathComponent("Other"), inMemory: true)
        XCTAssertEqual(try fresh.sourceURL(saved).resolvingSymlinksInPath(), external.resolvingSymlinksInPath())
        library.addFolder(external); try await waitForScan(library)
        XCTAssertEqual(library.sources.filter { !$0.isOwned }.count, 1)
        XCTAssertEqual(library.sources.first { !$0.isOwned }?.id, source.id)
    }
    @MainActor
    func testRemovingFolderDuringScanDoesNotResurrectSourceOrDeleteUserData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        let song = external.appendingPathComponent("Song.wav")
        try FileManager.default.copyItem(at: fixture, to: song)
        let library = LibraryStore(documents: root.appendingPathComponent("App"), inMemory: true)
        library.addFolder(external); try await waitForScan(library)
        let track = try XCTUnwrap(library.tracks.first)
        let source = try XCTUnwrap(library.sources.first { !$0.isOwned })
        library.favorite(track); library.createPlaylist("Keep me")
        let playlist = try XCTUnwrap(library.playlists.first)
        library.addTrack(track.id, to: playlist.id)
        library.rescan(); library.removeSource(source)
        try await waitForScan(library)
        XCTAssertFalse(library.sources.contains { $0.id == source.id })
        XCTAssertFalse(try XCTUnwrap(library.database).all("source", as: MusicSource.self).contains { $0.id == source.id })
        XCTAssertTrue(library.visibleTracks.isEmpty)
        XCTAssertEqual(library.track(track.id)?.locations, [])
        XCTAssertEqual(library.track(track.id)?.favorite, true)
        XCTAssertEqual(library.playlists.first?.trackIDs, [track.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.path))
        library.rescan(); try await waitForScan(library)
        XCTAssertFalse(library.sources.contains { $0.id == source.id })
        library.addFolder(external); try await waitForScan(library)
        XCTAssertEqual(library.visibleTracks.first?.id, track.id)
        XCTAssertEqual(library.visibleTracks.first?.favorite, true)
    }
    @MainActor
    func testReconnectRetainsSourceIdentityRestrictionsAndRejectsInvalidFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let library = LibraryStore(documents: root.appendingPathComponent("App"), inMemory: true)
        library.addFolder(external); try await waitForScan(library)
        let source = try XCTUnwrap(library.sources.first { !$0.isOwned })
        library.setEnabled(source.id, enabled: false)
        library.addFolder(external, reconnecting: source.id)
        XCTAssertFalse(library.scanning)
        XCTAssertEqual(library.sources.first { $0.id == source.id }?.enabled, false)
        XCTAssertEqual(library.sources.first { $0.id == source.id }?.needsReconnect, false)
        let before = library.sources
        library.addFolder(root.appendingPathComponent("Missing"))
        XCTAssertNotNil(library.errorMessage)
        XCTAssertEqual(library.sources, before)
    }
    @MainActor
    func testAudioQualityExtractionLegacyDecodingAndSharedFolderGuide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(documents: root, inMemory: true)
        let guide = root.appendingPathComponent("Cassette Guide.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: guide.path))
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.tracks.count, 1, "The transfer guide is not indexed as audio")
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertEqual(track.audioFormat, "WAV / PCM")
        XCTAssertEqual(try XCTUnwrap(track.bitrate), 352800, "22.05 kHz mono 16-bit PCM has 352800 encoded bits/sec")
        XCTAssertTrue(track.audioQualityLabel.contains("kbps"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        json.removeValue(forKey: "audioFormat"); json.removeValue(forKey: "bitrate")
        let legacy = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.audioFormat); XCTAssertNil(legacy.bitrate)
        XCTAssertEqual(legacy.audioQualityLabel, "WAV · Bitrate unavailable")
        XCTAssertEqual(legacy.id, track.id)
    }
    @MainActor
    func testLargerScrubberThumbKeeps44PointSurfaceAndAccessibleRange() async throws {
        var position = 15.0
        var editingEvents: [Bool] = []
        let view = CompactPlaybackSlider(value: Binding(get: { position }, set: { position = $0 }), maximum: 100, editingChanged: { editingEvents.append($0) })
        let host = UIHostingController(rootView: view.frame(width: 272, height: 44))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
        defer { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
        host.view.frame = CGRect(x: 0, y: 0, width: 272, height: 44)
        host.beginAppearanceTransition(true, animated: false); host.endAppearanceTransition()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        func find(_ root: UIView) -> UISlider? {
            if let slider = root as? UISlider { return slider }
            return root.subviews.compactMap(find).first
        }
        let slider = find(host.view)
        let scrubber = try XCTUnwrap(slider as? ScrubbingSlider)
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(scrubber.currentThumbImage?.size.width, 24)
        #endif
        // Catalyst supplies a native NSSlider and ignores UIKit thumb images; iOS uses the 24-point asset.
        XCTAssertGreaterThanOrEqual(host.view.bounds.height, 44)
        XCTAssertTrue(scrubber.point(inside: CGPoint(x: 100, y: scrubber.bounds.midY - 21), with: nil))
        XCTAssertTrue(scrubber.point(inside: CGPoint(x: 100, y: scrubber.bounds.midY + 21), with: nil))
        XCTAssertEqual(slider?.maximumValue, 100)
        XCTAssertEqual(slider?.accessibilityLabel, "Playback position")
        scrubber.sendActions(for: .touchDown)
        scrubber.sendActions(for: .touchDown) // Duplicate begin notifications must not restart the scrub.
        scrubber.value = 75; scrubber.sendActions(for: .valueChanged)
        XCTAssertEqual(position, 75)
        scrubber.sendActions(for: .touchUpInside)
        XCTAssertEqual(editingEvents, [true, false])
        editingEvents.removeAll()
        scrubber.value = 33; scrubber.sendActions(for: .valueChanged) // VoiceOver-style non-touch change.
        XCTAssertEqual(position, 33)
        XCTAssertEqual(editingEvents, [false])
    }

    @MainActor
    func testOwnedSubfolderSelectionAndDisconnectedDuplicateSuppression() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("App")
        let ownedMusic = owned.appendingPathComponent("Music")
        let externalMusic = root.appendingPathComponent("OnMyIPod/Music")
        try FileManager.default.createDirectory(at: ownedMusic, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalMusic, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: ownedMusic.appendingPathComponent("Track1.wav"))
        try FileManager.default.copyItem(at: fixture, to: externalMusic.appendingPathComponent("Track1.wav"))

        let library = LibraryStore(documents: owned, inMemory: true)
        // Selecting a "Music" subfolder inside Cassette's own Documents container must reuse the owned source, not add an external duplicate.
        library.addFolder(ownedMusic)
        try await waitForScan(library)
        XCTAssertEqual(library.sources.count, 1)
        XCTAssertTrue(library.sources[0].isOwned)
        XCTAssertEqual(library.visibleTracks.count, 1)

        // Add the external "OnMyIPod/Music" folder with the same song copy.
        library.addFolder(externalMusic)
        try await waitForScan(library)
        XCTAssertEqual(library.sources.count, 2)
        let externalSource = try XCTUnwrap(library.sources.first { !$0.isOwned })

        // Simulate the external folder becoming unavailable / needing reconnect (e.g., moved or stale bookmark).
        try FileManager.default.removeItem(at: externalMusic)
        library.rescan(only: externalSource.id)
        try await waitForScan(library)
        XCTAssertEqual(library.sources.first { $0.id == externalSource.id }?.needsReconnect, true)

        // Because the same song is still available in Cassette's owned folder, visibleTracks must NOT show a duplicate "Unavailable · reconnect folder" row.
        XCTAssertEqual(library.visibleTracks.count, 1)
        XCTAssertTrue(library.visibleTracks.allSatisfy(\.available))

        // Re-creating and re-adding the external "Music" folder without tapping "Reconnect" reuses the disconnected source ID instead of creating a third source.
        try FileManager.default.createDirectory(at: externalMusic, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: externalMusic.appendingPathComponent("Track1.wav"))
        library.addFolder(externalMusic)
        try await waitForScan(library)
        XCTAssertEqual(library.sources.filter { !$0.isOwned }.count, 1)
        XCTAssertEqual(library.sources.first { !$0.isOwned }?.id, externalSource.id)
        XCTAssertEqual(library.sources.first { !$0.isOwned }?.needsReconnect, false)
    }
}
