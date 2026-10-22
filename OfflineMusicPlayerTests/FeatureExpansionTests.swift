import XCTest
import SwiftUI
import Combine
@testable import OfflineMusicPlayer

final class FeatureExpansionTests: XCTestCase {
    func testM3UParsingKeepsOrderAndDuplicatesButRejectsRemoteAndEscapingPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/Cassette-parser/Music")
        let playlist = root.appendingPathComponent("Lists/Mix.m3u8")
        let input = "\u{feff}#EXTM3U\r\n../A.wav\r\n#EXTINF:12,A\n../B.wav\n../A.wav\nhttps://example.invalid/a.mp3\n../../../outside.wav\nfile://remote-server/tmp/a.wav\n../Missing.wav"
        let result = try M3UParser.parse(Data(input.utf8), playlist: playlist, root: root)
        XCTAssertEqual(result.entries, ["A.wav", "B.wav", "A.wav", "Missing.wav"])
        XCTAssertEqual(result.issues.count, 3)
        let windows = try M3UParser.parse(Data("..\\Album\\Song.wav".utf8), playlist: playlist, root: root)
        XCTAssertEqual(windows.entries, ["Album/Song.wav"])
    }
    @MainActor
    func testGrantedProviderFolderAndM3URefreshPersistWithoutDuplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let documents = root.appendingPathComponent("App")
        let provider = root.appendingPathComponent("File Provider Storage/Local Music")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        for name in ["A", "B"] { try FileManager.default.copyItem(at: fixture, to: provider.appendingPathComponent(name + ".wav")) }
        let manifest = provider.appendingPathComponent("Mix.m3u8")
        try "#EXTM3U\nB.wav\nA.wav\nB.wav\nMissing.wav".write(to: manifest, atomically: true, encoding: .utf8)
        let library = LibraryStore(documents: documents, inMemory: true)
        library.addFolder(provider); try await waitForScan(library)
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.tracks.count, 2)
        let playlist = try XCTUnwrap(library.playlists.first)
        XCTAssertEqual(playlist.trackIDs.compactMap(library.track).map(\.title), ["B", "A", "B"])
        XCTAssertEqual(playlist.unresolvedPaths, ["Missing.wav"])
        let source = try XCTUnwrap(library.sources.first { !$0.isOwned })
        let persisted = try XCTUnwrap(library.database).all("source", as: MusicSource.self)
        let saved = try XCTUnwrap(persisted.first { $0.id == source.id })
        XCTAssertEqual(try library.sourceURL(saved).resolvingSymlinksInPath(), provider.resolvingSymlinksInPath())
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.playlists.count, 1)
        XCTAssertEqual(library.playlists.first?.id, playlist.id)
        try "A.wav".write(to: manifest, atomically: true, encoding: .utf8)
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.playlists.first?.trackIDs.compactMap(library.track).map(\.title), ["A"])
        let stored = try XCTUnwrap(library.database).all("playlist", as: MusicPlaylist.self)
        XCTAssertEqual(stored.first?.id, playlist.id)
        XCTAssertEqual(stored.first?.unresolvedPaths, [])
    }
    @MainActor
    func testAdjacentLyricsAddedAndChangedInvalidateOnlyThatTrackMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        let original = try XCTUnwrap(library.tracks.first)
        let lrc = root.appendingPathComponent("Song.lrc")
        try "[00:01]First line".write(to: lrc, atomically: true, encoding: .utf8)
        library.rescan(); try await waitForScan(library)
        let withLyrics = try XCTUnwrap(library.track(original.id))
        XCTAssertEqual(withLyrics.lyrics, "[00:01]First line")
        XCTAssertNotEqual(withLyrics.fingerprint, original.fingerprint)
        try "[00:01]Updated longer line".write(to: lrc, atomically: true, encoding: .utf8)
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.track(original.id)?.lyrics, "[00:01]Updated longer line")
        try FileManager.default.removeItem(at: lrc)
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(library.track(original.id)?.fingerprint, original.fingerprint)
    }
    @MainActor
    func testForegroundScanThrottleLeavesManualScanAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        library.rescanIfNeeded()
        XCTAssertFalse(library.scanning)
        library.rescan()
        XCTAssertTrue(library.scanning)
        try await waitForScan(library)
    }
    func testTimedLyricLookupHandlesExactTimestampsOffsetsAndBackwardSeek() {
        let lines = LRCParser.parse("[offset:100]\n[00:01]A\n[00:02]B\n[00:02]C\n[00:04]D")
        XCTAssertNil(LRCParser.activeLine(in: lines, at: 0))
        XCTAssertEqual(LRCParser.activeLine(in: lines, at: 1.1), 0)
        XCTAssertEqual(LRCParser.activeLine(in: lines, at: 2.1), 2)
        XCTAssertEqual(LRCParser.activeLine(in: lines, at: 10), 3)
        XCTAssertEqual(LRCParser.activeLine(in: lines, at: 1.5), 0)
        XCTAssertNil(LRCParser.activeLine(in: lines, at: .nan))
    }
    @MainActor
    func testRapidPlayPauseCancelsPendingActivationAndSwipePreviousSelectsTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        for name in ["A", "B"] { try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name + ".wav")) }
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        let player = PlaybackCoordinator(); player.connect(library)
        player.play(library.sortedTracks)
        XCTAssertTrue(player.playbackRequested)
        player.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(player.isPlaying); XCTAssertFalse(player.playbackRequested)
        player.play(library.sortedTracks, startingAt: library.sortedTracks[1]); try await waitForPlayback(player)
        player.seek(to: 5); player.previousTrack()
        XCTAssertEqual(player.currentTrack?.title, "A")
        player.pause()
    }
    @MainActor
    func testClockTicksDoNotPublishGeneralPlayerUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        let player = PlaybackCoordinator(); player.connect(library)
        player.play(library.sortedTracks); try await waitForPlayback(player)
        player.setPlayerVisible(true); player.setLyricsTracking(true)
        var generalUpdates = 0, ticks = 0
        let general = player.objectWillChange.sink { generalUpdates += 1 }
        let clock = player.clock.$position.dropFirst().sink { _ in ticks += 1 }
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertGreaterThanOrEqual(ticks, 2)
        XCTAssertEqual(generalUpdates, 0, "Clock ticks must not invalidate library/list consumers")
        general.cancel(); clock.cancel(); player.pause()
    }
    func testArtistMatchingAvoidsUnrelatedPagesAndSupportsBandsAndDuos() {
        let pages: [[String: Any]] = [
            ["title":"Queen", "description":"female monarch"],
            ["title":"Queen (band)", "description":"British rock band"],
            ["title":"Queen discography", "description":"discography"]]
        XCTAssertEqual(ArtistPhotoStore.match(pages, artist: "Queen")?["title"] as? String, "Queen (band)")
        XCTAssertNotNil(ArtistPhotoStore.match([["title":"Daft Punk", "description":"French electronic music duo"]], artist: "Daft Punk"))
        XCTAssertNil(ArtistPhotoStore.match(pages, artist: "Different Artist"))
        XCTAssertNil(ArtistPhotoStore.match([["title":"Alex (singer)", "description":"American singer"], ["title":"Alex (musician)", "description":"British musician"]], artist: "Alex"))
        XCTAssertEqual(ArtistPhotoStore.plain("<a href='x'>Creator</a> &amp; Team"), "Creator & Team")
    }
    @MainActor
    func testSyncedLyricsCompactRender() async throws {
        let lines = LRCParser.parse((0..<15).map { "[00:\(String(format: "%02d", $0))]Line \($0 + 1) of local lyrics" }.joined(separator: "\n"))
        let host = UIHostingController(rootView: SyncedLyricsView(lines: lines, position: 8, seek: { _ in }).ignoresSafeArea())
        host.overrideUserInterfaceStyle = .dark
        let bounds = CGRect(x: 0, y: 0, width: 272, height: 200)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
        defer { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
        host.view.frame = bounds
        host.beginAppearanceTransition(true, animated: false); host.endAppearanceTransition()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        _ = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.view.layoutIfNeeded()
        let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        let pngData = try XCTUnwrap(rendered.pngData())
        try pngData.write(to: URL(fileURLWithPath: "/tmp/Cassette-synced-lyrics.png"))
        if let cgImage = UIImage(data: pngData)?.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let bpp = cgImage.bitsPerPixel / 8
            let bpr = cgImage.bytesPerRow
            let bgLevel = Int(bytes[0])
            // The very top and very bottom scanlines (y = 0..2, y = 197..199) are at the 0-alpha ends of LyricsEdgeFadeMask,
            // so any scrolled lyric content at those borders must blend completely into the container background.
            for edgeY in [0, 1, 2, 197, 198, 199] {
                for x in 0..<240 {
                    let offset = edgeY * bpr + x * bpp
                    let level = Int(bytes[offset])
                    XCTAssertLessThanOrEqual(abs(level - bgLevel), 2, "Lyrics edge pixel at (\(x), \(edgeY)) should be fully faded into background")
                }
            }
        }
    }
}
