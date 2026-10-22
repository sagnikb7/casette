import XCTest
import SwiftUI
@testable import OfflineMusicPlayer

final class WidgetTests: XCTestCase {
    func testWidgetRecoveryWritesEmptySnapshotAndRepairsCorruptState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let first = try await store.publish(title: "", artist: "", artwork: nil)
        XCTAssertTrue(first, "No file must not be mistaken for an unchanged empty snapshot")
        XCTAssertNotNil(CassetteWidgetConfiguration.readValidSnapshot(from: directory))
        let unchanged = try await store.publish(title: "", artist: "", artwork: nil)
        XCTAssertFalse(unchanged)
        let forced = try await store.publish(title: "", artist: "", artwork: nil, force: true)
        XCTAssertTrue(forced, "Recovery must write even unchanged state")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        let repaired = try await store.publish(title: "", artist: "", artwork: nil)
        XCTAssertTrue(repaired)
        XCTAssertEqual(CassetteWidgetConfiguration.readValidSnapshot(from: directory), .empty)
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(CassetteWidgetConfiguration.retryDate(after: date).timeIntervalSince(date), 1800)
    }

    @MainActor
    func testWidgetArtworkIsDownsampledAndUnsafeOrBrokenCoversFallBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1024), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        }
        try XCTUnwrap(large.jpegData(compressionQuality: 0.7)).write(to: source)
        let directory = root.appendingPathComponent("Shared")
        let store = WidgetSnapshotStore(directory: directory)
        _ = try await store.publish(title: "Track", artist: "Artist", artwork: source)
        let snapshot = CassetteWidgetConfiguration.read(from: directory)
        let thumbnail = try XCTUnwrap(CassetteWidgetConfiguration.artwork(for: snapshot, in: directory))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 320)
        let cover = directory.appendingPathComponent(try XCTUnwrap(snapshot.artworkName))
        try FileManager.default.removeItem(at: cover)
        try FileManager.default.createSymbolicLink(at: cover, withDestinationURL: source)
        XCTAssertNil(CassetteWidgetConfiguration.artwork(for: snapshot, in: directory))
        try FileManager.default.removeItem(at: cover)
        try Data([1, 2, 3]).write(to: cover)
        XCTAssertNil(CassetteWidgetConfiguration.artwork(for: snapshot, in: directory))
        XCTAssertEqual(CassetteWidgetConfiguration.read(from: directory).title, "Track")
        // Same source filename with new bytes must produce a new shared cover identity.
        try Data([4, 5, 6]).write(to: source)
        let changed = try await store.publish(title: "Track", artist: "Artist", artwork: source)
        XCTAssertTrue(changed)
        XCTAssertNotEqual(CassetteWidgetConfiguration.read(from: directory).artworkName, snapshot.artworkName)
        let missing = root.appendingPathComponent("missing.jpg")
        _ = try await store.publish(title: "Still visible", artist: "Artist", artwork: missing)
        XCTAssertEqual(CassetteWidgetConfiguration.read(from: directory).title, "Still visible")
        XCTAssertNil(CassetteWidgetConfiguration.read(from: directory).artworkName)
    }

    func testWidgetSnapshotRoundTripSuppressesUnchangedWritesAndRejectsUnsafePaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let first = try await store.publish(title: "Track", artist: "Artist", artwork: nil)
        XCTAssertTrue(first)
        XCTAssertEqual(CassetteWidgetConfiguration.read(from: directory), WidgetSnapshot(title: "Track", artist: "Artist", artworkName: nil))
        let file = directory.appendingPathComponent("snapshot.json")
        let before = try Data(contentsOf: file)
        let unchanged = try await store.publish(title: "Track", artist: "Artist", artwork: nil)
        XCTAssertFalse(unchanged); XCTAssertEqual(try Data(contentsOf: file), before)
        let unsafe = WidgetSnapshot(title: "Track", artist: "Artist", artworkName: "cover-../../private.jpg")
        try JSONEncoder().encode(unsafe).write(to: file)
        XCTAssertEqual(CassetteWidgetConfiguration.read(from: directory), .empty)
        try Data(repeating: 0, count: 65_000).write(to: file)
        XCTAssertEqual(CassetteWidgetConfiguration.read(from: directory), .empty)
    }
    func testWidgetSnapshotSharesOnlyBoundedCoversAndLimitsStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Shared")
        let store = WidgetSnapshotStore(directory: directory)
        for index in 0..<4 {
            let cover = root.appendingPathComponent("Art\(index).jpg")
            try Data([1, 2, UInt8(index)]).write(to: cover)
            _ = try await store.publish(title: "Track \(index)", artist: "Artist", artwork: cover)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "jpg" }.count, 2)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 1)
        let restored = CassetteWidgetConfiguration.read(from: directory)
        XCTAssertEqual(restored.title, "Track 3")
        XCTAssertNotNil(restored.artworkName)
        let oversized = root.appendingPathComponent("Huge.jpg")
        try Data(repeating: 0, count: 2_000_001).write(to: oversized)
        _ = try await store.publish(title: "Track 4", artist: "Artist", artwork: oversized)
        XCTAssertNil(CassetteWidgetConfiguration.read(from: directory).artworkName)
        let unavailable = try await WidgetSnapshotStore(directory: nil).publish(title: "Unavailable", artist: "Artist", artwork: nil)
        XCTAssertFalse(unavailable)
    }
    func testWidgetLinksOnlyOpenKnownDestinationsWithoutAutoplayCommands() {
        XCTAssertTrue(CassetteWidgetConfiguration.opensPlayer(CassetteWidgetConfiguration.playerURL))
        XCTAssertTrue(CassetteWidgetConfiguration.opensLibrary(CassetteWidgetConfiguration.libraryURL))
        for value in ["https://example.com/player", "cassette://player?play=true", "cassette://player/private", "cassette://user@player", "cassette://player:99", "cassette://player#file", "file:///private/music.mp3"] {
            let url = URL(string: value)!
            XCTAssertFalse(CassetteWidgetConfiguration.opensPlayer(url))
            XCTAssertFalse(CassetteWidgetConfiguration.opensLibrary(url))
        }
    }
    @MainActor
    func testNativeWidgetSizesAndEmptyStateRender() async throws {
        let snapshot = WidgetSnapshot(title: "Night Drive", artist: "Mira Vale", artworkName: nil)
        for (name, square, width, content) in [("square", true, 141.0, snapshot), ("horizontal", false, 292.0, snapshot), ("empty", true, 141.0, WidgetSnapshot.empty), ("empty-horizontal", false, 292.0, WidgetSnapshot.empty)] {
            let view = CassetteWidgetCard(snapshot: content, artwork: nil, square: square).frame(width: width, height: 141).cornerRadius(22).ignoresSafeArea()
            let host = UIHostingController(rootView: view)
            let bounds = CGRect(x: 0, y: 0, width: width, height: 141)
            host.view.frame = bounds; host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in host.view.drawHierarchy(in: bounds, afterScreenUpdates: true) }
            XCTAssertEqual(image.size, bounds.size)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/Cassette-widget-\(name).png"))
        }
    }

    func testProvisionedAppGroupExtractionAndUserDefaultsFallback() async throws {
        let cmsPrefix = Data([0x30, 0x82, 0x01, 0x00])
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>com.apple.security.application-groups</key>
                <array>
                    <string>group.com.local.offlinemusicplayer.TEAM123</string>
                </array>
            </dict>
        </dict>
        </plist>
        """.data(using: .utf8)!
        let cmsSuffix = Data([0x00, 0x00])
        let mobileprovision = cmsPrefix + plistXML + cmsSuffix
        XCTAssertEqual(
            CassetteWidgetConfiguration.extractAppGroups(from: mobileprovision),
            ["group.com.local.offlinemusicplayer.TEAM123"]
        )
        let candidates = CassetteWidgetConfiguration.candidateAppGroups()
        XCTAssertTrue(candidates.contains(CassetteWidgetConfiguration.appGroup))

        let suiteName = "CassetteWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cover.jpg")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120), format: format).image { ctx in
            UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: source)

        let store = WidgetSnapshotStore(directory: nil, defaults: defaults)
        let published = try await store.publish(title: "Sideloaded Song", artist: "Sideloaded Artist", artwork: source)
        XCTAssertTrue(published)

        let restored = CassetteWidgetConfiguration.read(from: nil, defaults: defaults)
        XCTAssertEqual(restored.title, "Sideloaded Song")
        XCTAssertEqual(restored.artist, "Sideloaded Artist")
        XCTAssertNotNil(restored.artworkName)
        let restoredImage = CassetteWidgetConfiguration.artwork(for: restored, in: nil, defaults: defaults)
        XCTAssertNotNil(restoredImage)
    }
}
