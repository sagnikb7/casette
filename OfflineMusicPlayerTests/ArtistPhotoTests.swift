import XCTest
import SwiftUI
@testable import OfflineMusicPlayer

final class ArtistPhotoTests: XCTestCase {
    @MainActor
    func testITunes600ArtworkAndLazyMusicBrainzDetailsCacheAndRespectOptOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "artistPhotosEnabled")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format).image { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            }.jpegData(compressionQuality: 0.85)
        )
        ArtistProtocol.configure(image: jpeg, mode: .itunesAndMusicBrainz)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ArtistProtocol.self]
        let service = ArtistPhotoStore(directory: root, session: URLSession(configuration: configuration), preferences: preferences)

        // Stage 1: Row lookup fetches only iTunes search + 600x600 image (2 requests, no MusicBrainz call).
        let rowResult = await service.photo(for: "Daft Punk", includeDetails: false)
        let rowPhoto = try XCTUnwrap(rowResult)
        XCTAssertEqual(rowPhoto.filename, "600x600bb.jpg")
        XCTAssertEqual(rowPhoto.genre, "Electronic")
        XCTAssertEqual(rowPhoto.topAlbums, ["Discovery", "Random Access Memories"])
        let cachedWidth = try XCTUnwrap(UIImage(contentsOfFile: rowPhoto.fileURL.path)).size.width
        XCTAssertEqual(cachedWidth, 600, accuracy: 1)
        XCTAssertEqual(ArtistProtocol.count, 2, "Row thumbnail load must not query MusicBrainz eagerly")
        XCTAssertEqual(ArtistProtocol.musicBrainzCount, 0)

        // Repeated row lookup hits the 600x600 disk cache with zero network requests.
        _ = await service.photo(for: "Daft Punk", includeDetails: false)
        XCTAssertEqual(ArtistProtocol.count, 2)

        // Stage 2: Opening the artist detail page lazily fetches MusicBrainz metadata once.
        let detailResult = await service.photo(for: "Daft Punk", includeDetails: true)
        let detailedPhoto = try XCTUnwrap(detailResult)
        XCTAssertEqual(ArtistProtocol.musicBrainzCount, 1)
        XCTAssertEqual(ArtistProtocol.count, 3)
        XCTAssertEqual(detailedPhoto.origin, "Paris, France")
        XCTAssertEqual(detailedPhoto.lifeSpan, "1993–2021")
        XCTAssertEqual(detailedPhoto.artistType, "Group")
        XCTAssertEqual(detailedPhoto.tags, ["electronic", "house", "french touch"])
        let summary = try XCTUnwrap(detailedPhoto.summary)
        XCTAssertTrue(summary.contains("French electronic music duo"))
        XCTAssertTrue(summary.contains("Paris, France"))
        XCTAssertTrue(summary.contains("1993–2021"))

        // Subsequent detail lookup reuses the enriched cache without hitting MusicBrainz again.
        _ = await service.photo(for: "Daft Punk", includeDetails: true)
        XCTAssertEqual(ArtistProtocol.count, 3)

        // Disabling artist photos returns cached data for existing artists and blocks new network requests.
        preferences.set(false, forKey: "artistPhotosEnabled")
        let cached = await service.photo(for: "Daft Punk", includeDetails: true)
        XCTAssertNotNil(cached)
        let other = await service.photo(for: "Other Singer", includeDetails: true)
        XCTAssertNil(other)
        XCTAssertEqual(ArtistProtocol.count, 3)
    }

    @MainActor
    func testWikimediaFallbackCachesPixelsAndAttribution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "artistPhotosEnabled")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let jpeg = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            }.jpegData(compressionQuality: 0.8)
        )
        ArtistProtocol.configure(image: jpeg, mode: .wikimediaFallback)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ArtistProtocol.self]
        let service = ArtistPhotoStore(directory: root, session: URLSession(configuration: configuration), preferences: preferences)
        let result = await service.photo(for: "Test Singer")
        let photo = try XCTUnwrap(result)
        XCTAssertEqual(photo.creator, "Test Creator")
        XCTAssertEqual(photo.license, "CC BY 4.0")
        XCTAssertEqual(photo.sourceURL.host, "commons.wikimedia.org")
        let cachedWidth = try XCTUnwrap(UIImage(contentsOfFile: photo.fileURL.path)).size.width
        XCTAssertEqual(cachedWidth, 600, accuracy: 1)
    }

    @MainActor
    func testNoMatchAndOfflineFailureAreNegativelyCached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        ArtistProtocol.configure(image: Data(), mode: .offline)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ArtistProtocol.self]
        let service = ArtistPhotoStore(directory: root, session: URLSession(configuration: configuration), preferences: preferences)
        let first = await service.photo(for: "Test Singer")
        let second = await service.photo(for: "Test Singer")
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(ArtistProtocol.count, 2, "Negative cache stops repeated lookups after initial iTunes + fallback attempt")
    }
}

private final class ArtistProtocol: URLProtocol {
    enum Mode { case itunesAndMusicBrainz, wikimediaFallback, offline }
    private static let lock = NSLock()
    private static var image = Data()
    private static var requests = 0
    private static var mbRequests = 0
    private static var mode: Mode = .itunesAndMusicBrainz
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static var musicBrainzCount: Int { lock.lock(); defer { lock.unlock() }; return mbRequests }
    static func configure(image: Data, mode: Mode) {
        lock.lock(); defer { lock.unlock() }
        Self.image = image; Self.mode = mode; requests = 0; mbRequests = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests += 1
        if url.host == "musicbrainz.org" { Self.mbRequests += 1 }
        let currentMode = Self.mode
        let image = Self.image
        Self.lock.unlock()

        if currentMode == .offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let data: Data
        let isImage = url.host == "thumb.wikimedia.org" || (url.host?.hasSuffix(".mzstatic.com") == true)
        if isImage {
            data = image
        } else if url.host == "itunes.apple.com" {
            if currentMode == .wikimediaFallback {
                data = Data(#"{"resultCount":0,"results":[]}"#.utf8)
            } else {
                data = Data(#"{"resultCount":2,"results":[{"artistName":"Daft Punk","collectionName":"Discovery","primaryGenreName":"Electronic","releaseDate":"2001-03-12T08:00:00Z","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/aa/bb/cc/100x100bb.jpg","artistViewUrl":"https://music.apple.com/us/artist/daft-punk/5468295"},{"artistName":"Daft Punk","collectionName":"Random Access Memories","primaryGenreName":"Electronic","releaseDate":"2013-05-17T08:00:00Z","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/aa/bb/cc/100x100bb.jpg"}]}"#.utf8)
            }
        } else if url.host == "musicbrainz.org" {
            data = Data(#"{"artists":[{"name":"Daft Punk","type":"Group","disambiguation":"French electronic music duo","country":"FR","area":{"name":"France"},"begin-area":{"name":"Paris"},"life-span":{"begin":"1993","end":"2021","ended":true},"tags":[{"name":"electronic","count":10},{"name":"house","count":8},{"name":"french touch","count":6}]}]}"#.utf8)
        } else if query.contains(where: { $0.name == "generator" }) {
            data = Data(#"{"query":{"pages":[{"title":"Test Singer","description":"British singer","pageimage":"Photo.jpg"}]}}"#.utf8)
        } else {
            data = Data(#"{"query":{"pages":[{"imageinfo":[{"thumburl":"https://thumb.wikimedia.org/test.jpg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Photo.jpg","extmetadata":{"ExtraProviderField":{"value":42},"Artist":{"value":"<b>Test Creator</b>"},"LicenseShortName":{"value":"CC BY 4.0"},"LicenseUrl":{"value":"https://creativecommons.org/licenses/by/4.0"}}}]}]}}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isImage ? "image/jpeg" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
