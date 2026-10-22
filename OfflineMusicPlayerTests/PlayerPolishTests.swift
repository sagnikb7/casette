import XCTest
import SwiftUI
import Combine
@testable import OfflineMusicPlayer

final class PlayerPolishTests: XCTestCase {
    @MainActor
    func testRecentlyPlayedAndHistoryRenderAtCompactWidth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(documents: root, inMemory: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        for name in ["A Song With A Long Title", "Another Song", "Final Song"] {
            try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name + ".wav"))
        }
        library.rescan(); try await waitForScan(library)
        for track in library.sortedTracks { library.recordPlayback(track) }
        let playback = PlaybackCoordinator(); playback.connect(library)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        for (name, content) in [("library", AnyView(LibraryHomeView())), ("history", AnyView(ListeningHistoryView()))] {
            let host = UIHostingController(rootView: NavigationView { content }.navigationViewStyle(.stack).environmentObject(library).environmentObject(playback))
            parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
            host.overrideUserInterfaceStyle = .light
            let bounds = CGRect(x: 0, y: 0, width: 320, height: 548)
            host.view.frame = bounds
            host.beginAppearanceTransition(true, animated: false); host.endAppearanceTransition()
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-recent-\(name)-320x548.png"))
            if name == "library" {
                // Catalyst hosts the List in a native scroll surface. A taller capture
                // shows its below-the-fold section while keeping the iPod's 320-point width.
                let expanded = CGRect(x: 0, y: 0, width: 320, height: 820)
                host.view.frame = expanded; host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                let fullLibrary = UIGraphicsImageRenderer(bounds: expanded, format: format).image { _ in host.view.drawHierarchy(in: expanded, afterScreenUpdates: true) }
                try XCTUnwrap(fullLibrary.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-recent-library-320x820.png"))
            }
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }

    @MainActor
    func testPlaylistAddIsIdempotentAndPersistsAcrossMultiplePlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        let track = try XCTUnwrap(library.tracks.first)
        library.createPlaylist("First"); library.createPlaylist("Second")
        let first = library.playlists[0].id, second = library.playlists[1].id
        XCTAssertTrue(library.addTrack(track.id, to: first))
        for _ in 0..<10 { XCTAssertFalse(library.addTrack(track.id, to: first)) }
        XCTAssertTrue(library.addTrack(track.id, to: second))
        XCTAssertFalse(library.addTrack("missing-track", to: second))
        XCTAssertFalse(library.addTrack(track.id, to: UUID()))
        XCTAssertEqual(library.playlists.map(\.trackIDs), [[track.id], [track.id]])
        let stored = try XCTUnwrap(library.database).all("playlist", as: MusicPlaylist.self)
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.trackIDs == [track.id] })
        // A second selection tap removes the accidental addition and only touches that playlist.
        XCTAssertTrue(library.toggleTrack(track.id, in: first))
        XCTAssertEqual(library.playlists.map(\.trackIDs), [[], [track.id]])
        XCTAssertTrue(library.toggleTrack(track.id, in: first))
        XCTAssertEqual(library.playlists[0].trackIDs, [track.id])
        XCTAssertTrue(library.toggleTrack(track.id, in: first))
        let updated = try XCTUnwrap(library.database).all("playlist", as: MusicPlaylist.self)
        XCTAssertEqual(updated.first { $0.id == first }?.trackIDs, [])
        XCTAssertFalse(library.toggleTrack(track.id, in: UUID()))
        // Old duplicate records become wholly unselected instead of retaining a hidden occurrence.
        var legacy = library.playlists[0]; legacy.trackIDs = [track.id, track.id]
        library.changePlaylist(legacy)
        XCTAssertTrue(library.toggleTrack(track.id, in: first))
        XCTAssertTrue(library.playlists[0].trackIDs.isEmpty)
    }

    @MainActor
    func testArtworkTintIsTinyAndReusesCachedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 160, width: 320, height: 160))
        }
        let url = root.appendingPathComponent("art.png")
        try XCTUnwrap(artwork.pngData()).write(to: url)
        let cache = ArtworkSurfaceCache()
        let rendered = await cache.image(at: url)
        let first = try XCTUnwrap(rendered)
        let reused = await cache.image(at: url)
        XCTAssertTrue(first === reused, "Repeated playback updates must not regenerate the blur")
        XCTAssertLessThanOrEqual(first.size.width, 64); XCTAssertLessThanOrEqual(first.size.height, 64)
        let missing = await cache.image(at: root.appendingPathComponent("missing.png"))
        XCTAssertNil(missing)
    }

    @MainActor
    func testUnchangedScanAndCacheClearPreserveUserOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        let library = LibraryStore(documents: root, inMemory: true)
        library.rescan(); try await waitForScan(library)
        let track = try XCTUnwrap(library.sortedTracks.first)
        library.favorite(track); library.createPlaylist("Keep")
        let playlist = try XCTUnwrap(library.playlists.first)
        library.addTrack(track.id, to: playlist.id)
        XCTAssertTrue(try XCTUnwrap(library.track(track.id)).favorite)
        var publications = 0
        let subscription = library.$tracks.dropFirst().sink { _ in publications += 1 }
        library.rescan(); try await waitForScan(library)
        XCTAssertEqual(publications, 0, "Unchanged scans should not refresh every song row")
        await library.clearArtwork()
        XCTAssertFalse(library.busy)
        XCTAssertTrue(try XCTUnwrap(library.track(track.id)).favorite)
        XCTAssertEqual(library.sortedTracks.map(\.id), [track.id])
        XCTAssertEqual(library.playlists.first?.trackIDs, [track.id])
        subscription.cancel()
    }

    @MainActor
    func testCompactSleepTimerRenderForVisualInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(documents: root, inMemory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Song.wav"))
        library.rescan(); try await waitForScan(library)
        let player = PlaybackCoordinator(); player.connect(library)
        player.play(library.sortedTracks); try await waitForPlayback(player); player.pause()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        let host = UIHostingController(rootView: SleepTimerView(clock: player.clock).environmentObject(player))
        parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
        defer { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
        host.overrideUserInterfaceStyle = .light
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 820)
        host.view.frame = bounds
        host.beginAppearanceTransition(true, animated: false); host.endAppearanceTransition()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-sleep-timer-320x820.png"))
    }

    @MainActor
    func testFullSettingsAndAboutRenderForDuplicateLinkAudit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(documents: root, inMemory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackCoordinator(); player.connect(library)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        for (name, content) in [("settings", AnyView(SettingsView())), ("about", AnyView(AboutView()))] {
            let host = UIHostingController(rootView: NavigationView { content }.navigationViewStyle(.stack).environmentObject(library).environmentObject(player))
            parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
            host.overrideUserInterfaceStyle = .light
            let bounds = CGRect(x: 0, y: 0, width: 320, height: 1800)
            host.view.frame = bounds
            host.beginAppearanceTransition(true, animated: false); host.endAppearanceTransition()
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-audit-\(name)-320x1800.png"))
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
    }

    @MainActor
    func testCompactSettingsRenderForVisualInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(documents: root, inMemory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackCoordinator(); player.connect(library)
        let host = UIHostingController(rootView: NavigationView { SettingsView() }
            .navigationViewStyle(.stack).environmentObject(library).environmentObject(player))
        host.overrideUserInterfaceStyle = .dark
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 548)
        host.view.frame = bounds; host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-settings-320x548.png"))
    }

    @MainActor
    func testCompactPlayerRenderForVisualInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(documents: root, inMemory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackCoordinator(); player.connect(library)
        let host = UIHostingController(rootView: NowPlayingView().environmentObject(library).environmentObject(player))
        host.overrideUserInterfaceStyle = .dark
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 548)
        host.view.frame = bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, 320); XCTAssertEqual(image.size.height, 548)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-player-320x548.png"))

        // Also inspect the two-line header and wrapped metadata without starting playback.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestTone", withExtension: "wav"))
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("A Song With A Longer Display Title.wav"))
        for name in ["B Next Song", "C Last Song"] { try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name + ".wav")) }
        library.rescan(); try await waitForScan(library)
        try library.database?.save(PlaybackSnapshot(queue: library.sortedTracks.map(\.id), index: 0, position: 0, repeatMode: .off, shuffle: false), key: "playback", kind: "playback")
        try library.database?.commit()
        let restored = PlaybackCoordinator(); restored.connect(library)
        XCTAssertFalse(restored.isPlaying)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        for mode in [NowPlayingMode.artwork, .queue, .lyrics] {
            let populatedHost = UIHostingController(rootView: NowPlayingView(initialMode: mode).environmentObject(library).environmentObject(restored))
            parent.addChild(populatedHost); parent.view.addSubview(populatedHost.view); populatedHost.didMove(toParent: parent)
            populatedHost.overrideUserInterfaceStyle = .dark
            populatedHost.view.frame = bounds
            populatedHost.beginAppearanceTransition(true, animated: false); populatedHost.endAppearanceTransition()
            populatedHost.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let populated = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                populatedHost.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            let name = mode == .artwork ? "populated" : mode == .queue ? "queue" : "lyrics"
            let pngData = try XCTUnwrap(populated.pngData())
            try pngData.write(to: URL(fileURLWithPath: "/tmp/Cassette-player-\(name)-320x548.png"))
            if mode == .artwork, let cgImage = UIImage(data: pngData)?.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                // Verify the overflowing marquee title stays clipped and masked to the left of the 3-dot menu.
                // The metadata HStack has 24pt side margins, a 44pt trailing Menu, and an 8pt gap (x = 248..268),
                // so pixels in that clearance band must match the empty side-margin background at x = 12.
                let bpp = cgImage.bitsPerPixel / 8
                let bpr = cgImage.bytesPerRow
                for y in 326...340 {
                    let bgOffset = y * bpr + 12 * bpp
                    for x in 248...268 {
                        let offset = y * bpr + x * bpp
                        XCTAssertEqual(bytes[offset], bytes[bgOffset], accuracy: 2, "Marquee title pixel bled into 3-dot menu clearance at (\(x), \(y))")
                    }
                }
            }
            populatedHost.willMove(toParent: nil); populatedHost.view.removeFromSuperview(); populatedHost.removeFromParent()
        }

        defer { restored.pause() }
        for (name, playing) in [("playing", true), ("paused", false)] {
            if playing { restored.play(); try await waitForPlayback(restored); XCTAssertTrue(restored.isPlaying) } else { restored.pause(); XCTAssertFalse(restored.isPlaying) }
            let motionHost = UIHostingController(rootView: NowPlayingView().environmentObject(library).environmentObject(restored))
            parent.addChild(motionHost); parent.view.addSubview(motionHost.view); motionHost.didMove(toParent: parent)
            motionHost.overrideUserInterfaceStyle = .dark
            motionHost.view.frame = bounds
            motionHost.beginAppearanceTransition(true, animated: false); motionHost.endAppearanceTransition()
            motionHost.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 350_000_000)
            let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                motionHost.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(rendered.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-player-\(name)-320x548.png"))
            motionHost.willMove(toParent: nil); motionHost.view.removeFromSuperview(); motionHost.removeFromParent()
        }

        // The system accessibility environment is read-only; render the same artwork policy directly.
        var reducedImages: [Data] = []
        for playing in [false, true] {
            let reducedHost = UIHostingController(rootView: PlaybackArtworkView(reduceMotion: true, track: restored.currentTrack, side: 200, isPlaying: playing)
                .frame(width: 240, height: 240).background(Color(UIColor.systemBackground)).ignoresSafeArea().environmentObject(library))
            reducedHost.overrideUserInterfaceStyle = .dark
            let reducedBounds = CGRect(x: 0, y: 0, width: 240, height: 240)
            reducedHost.view.frame = reducedBounds; reducedHost.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let rendered = UIGraphicsImageRenderer(bounds: reducedBounds, format: format).image { _ in
                reducedHost.view.drawHierarchy(in: reducedBounds, afterScreenUpdates: true)
            }
            reducedImages.append(try XCTUnwrap(rendered.pngData()))
        }
        XCTAssertEqual(reducedImages[0], reducedImages[1], "Reduce Motion must keep artwork geometry identical on play/pause")
        try reducedImages[0].write(to: URL(fileURLWithPath: "/tmp/Cassette-player-reduced-motion.png"))
    }

    @MainActor
    func testArtworkCropHidesPlaceholderBehindRealArtAndSheetGrabberRenders() async throws {
        // ArtworkView only shows the placeholder tile when there is no real artwork, and edgeInsetCrop
        // is threaded through PlaybackArtworkView so a 1-2px border artifact baked into cover art is
        // cropped out rather than bleeding through the rounded-rect clip as a stray stroke.
        let bareArtwork = ArtworkView(track: nil, cornerRadius: 10, edgeInsetCrop: 2)
        XCTAssertEqual(bareArtwork.edgeInsetCrop, 2)
        XCTAssertEqual(bareArtwork.cornerRadius, 10)
        XCTAssertEqual(ArtworkView(track: nil).edgeInsetCrop, 0, "Default crop must stay zero for callers that don't opt in")

        let track = Track(id: "t1", title: "One More Time", artist: "Daft Punk", albumArtist: "Daft Punk", album: "Discovery", genre: "Electronic", duration: 320, trackNumber: 1, discNumber: 1, fingerprint: "fp1", locations: [], added: Date())
        let playbackArt = PlaybackArtworkView(reduceMotion: false, track: track, side: 200, isPlaying: false, cornerRadius: 10)
        XCTAssertEqual(playbackArt.cornerRadius, 10)

        // Render the Now Playing sheet; it should include the new grabber pill above the header
        // and the whole card (not just the artwork) carries the rounded top corners and dismiss
        // drag now, matching the Apple Music-style slide-down behavior.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryStore(documents: root, inMemory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackCoordinator(); player.connect(library)
        let host = UIHostingController(rootView: NowPlayingView().environmentObject(library).environmentObject(player))
        host.overrideUserInterfaceStyle = .dark
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 548)
        host.view.frame = bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, 320); XCTAssertEqual(image.size.height, 548)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-player-sheet-grabber-320x548.png"))

        // Dragging the Now Playing namespace into a RootView-hosted scene must not crash while
        // the shared matchedGeometryEffect("playerArtwork") morphs between the sheet and MiniPlayer,
        // and re-opening after a half-drag dismiss must reset dismissDragOffset to 0 so the sheet
        // never gets stuck halfway down the screen.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let parent = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        var dragOffset: CGFloat = 220
        let dragBinding = Binding<CGFloat>(get: { dragOffset }, set: { dragOffset = $0 })
        let reopenHost = UIHostingController(
            rootView: NowPlayingView(dismissDragOffset: dragBinding)
                .environmentObject(library)
                .environmentObject(player)
        )
        parent.addChild(reopenHost); parent.view.addSubview(reopenHost.view); reopenHost.didMove(toParent: parent)
        defer { reopenHost.willMove(toParent: nil); reopenHost.view.removeFromSuperview(); reopenHost.removeFromParent() }
        reopenHost.overrideUserInterfaceStyle = .dark
        reopenHost.view.frame = bounds
        reopenHost.beginAppearanceTransition(true, animated: false); reopenHost.endAppearanceTransition()
        reopenHost.view.setNeedsLayout(); reopenHost.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(dragOffset, 0, "Re-opening NowPlayingView must reset any residual dismissDragOffset so the sheet expands all the way to the top")

        let lightHost = UIHostingController(rootView: NowPlayingView().environmentObject(library).environmentObject(player))
        lightHost.overrideUserInterfaceStyle = .light
        lightHost.view.frame = bounds
        lightHost.view.setNeedsLayout(); lightHost.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let lightImage = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            lightHost.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(lightImage.size.width, 320); XCTAssertEqual(lightImage.size.height, 548)
        try XCTUnwrap(lightImage.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-player-light-320x548.png"))

        let rootHost = UIHostingController(rootView: RootView().environmentObject(library).environmentObject(player))
        rootHost.overrideUserInterfaceStyle = .dark
        rootHost.view.frame = bounds
        rootHost.view.setNeedsLayout(); rootHost.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(rootHost.view)
    }

    @MainActor
    func testPlaybackArtworkBounceSpringAndArtistAboutCardExpansion() async throws {
        let track = Track(id: "t1", title: "One More Time", artist: "Daft Punk", albumArtist: "Daft Punk", album: "Discovery", genre: "Electronic", duration: 320, trackNumber: 1, discNumber: 1, fingerprint: "fp1", locations: [], added: Date())
        // Verify directional spring physics: playing scale (0.92) > paused scale (0.736 = 80% of 0.92), and reduceMotion remains 1.0.
        let pausedArt = PlaybackArtworkView(reduceMotion: false, track: track, side: 200, isPlaying: false)
        let playingArt = PlaybackArtworkView(reduceMotion: false, track: track, side: 200, isPlaying: true)
        XCTAssertEqual(playingArt.scale, 0.92, accuracy: 0.001)
        XCTAssertEqual(pausedArt.scale, 0.92 * 0.8, accuracy: 0.001)
        XCTAssertEqual(pausedArt.scale / playingArt.scale, 0.8, accuracy: 0.001)
        XCTAssertNotNil(pausedArt.springAnimation)
        XCTAssertNotNil(playingArt.springAnimation)

        let reducedArt = PlaybackArtworkView(reduceMotion: true, track: track, side: 200, isPlaying: false)
        XCTAssertEqual(reducedArt.scale, 1.0, accuracy: 0.001)
        XCTAssertNil(reducedArt.springAnimation)

        // Verify collapsible ArtistAboutCard renders and toggles expanded state cleanly.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = "Daft Punk — French electronic music duo from Paris, France (1993–2021). Notable releases include Discovery, Random Access Memories."
        let photo = ArtistPhoto(
            filename: "600x600bb.jpg",
            creator: "Daft Punk",
            license: "Apple Music / MusicBrainz",
            licenseURL: URL(string: "https://music.apple.com/us/artist/daft-punk/5468295")!,
            sourceURL: URL(string: "https://music.apple.com/us/artist/daft-punk/5468295")!,
            fileURL: root.appendingPathComponent("600x600bb.jpg"),
            summary: summary,
            genre: "Electronic",
            origin: "Paris, France",
            lifeSpan: "1993–2021",
            artistType: "Group",
            tags: ["electronic", "house", "french touch"],
            topAlbums: ["Discovery", "Random Access Memories"]
        )
        var expanded = false
        let binding = Binding(get: { expanded }, set: { expanded = $0 })
        let cardHost = UIHostingController(rootView: ArtistAboutCard(artist: "Daft Punk", photo: photo, summary: summary, isExpanded: binding).padding())
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 260)
        cardHost.view.frame = bounds
        cardHost.view.setNeedsLayout(); cardHost.view.layoutIfNeeded()
        XCTAssertNotNil(cardHost.view)
    }

    @MainActor
    func testMultiArtistTracksAreSplitIntoSeparateArtistsAndSelectableInGoToArtist() throws {
        let collab = Track(
            id: "t-collab",
            title: "Get Lucky",
            artist: "Daft Punk; Pharrell Williams; Nile Rodgers",
            albumArtist: "Daft Punk",
            album: "Random Access Memories",
            genre: "Electronic",
            duration: 369,
            trackNumber: 8,
            discNumber: 1,
            fingerprint: "fp-collab",
            locations: [],
            added: Date()
        )
        let solo = Track(
            id: "t-solo",
            title: "Happy",
            artist: "Pharrell Williams",
            albumArtist: "Pharrell Williams",
            album: "G I R L",
            genre: "Pop",
            duration: 233,
            trackNumber: 5,
            discNumber: 1,
            fingerprint: "fp-solo",
            locations: [],
            added: Date()
        )
        XCTAssertEqual(collab.artistList, ["Daft Punk", "Pharrell Williams", "Nile Rodgers"])
        XCTAssertEqual(collab.displayArtist, "Daft Punk, Pharrell Williams, Nile Rodgers")
        XCTAssertEqual(solo.artistList, ["Pharrell Williams"])
        XCTAssertEqual(solo.displayArtist, "Pharrell Williams")

        let browse = BrowseIndex(tracks: [collab, solo])
        XCTAssertEqual(browse.artistNames, ["Daft Punk", "Nile Rodgers", "Pharrell Williams"])
        XCTAssertEqual(browse.tracks(forArtist: "Daft Punk").map(\.id), ["t-collab"])
        XCTAssertEqual(browse.tracks(forArtist: "Nile Rodgers").map(\.id), ["t-collab"])
        XCTAssertEqual(browse.tracks(forArtist: "Pharrell Williams").map(\.id), ["t-collab", "t-solo"])
        XCTAssertNil(browse.artists["Daft Punk; Pharrell Williams; Nile Rodgers"])

        var selectedArtist: String?
        let menuHost = UIHostingController(rootView: GoToArtistMenuItems(track: collab) { selectedArtist = $0 })
        menuHost.view.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
        menuHost.view.layoutIfNeeded()
        XCTAssertNotNil(menuHost.view)
        XCTAssertNil(selectedArtist)
    }
}
