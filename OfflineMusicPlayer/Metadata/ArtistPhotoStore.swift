import Foundation
import CryptoKit
import ImageIO
import UIKit

struct ArtistPhoto: Codable, Equatable {
    var filename: String
    var creator: String
    var license: String
    var licenseURL: URL
    var sourceURL: URL
    var fileURL: URL
    var summary: String? = nil
    var genre: String? = nil
    var origin: String? = nil
    var lifeSpan: String? = nil
    var artistType: String? = nil
    var tags: [String]? = nil
    var topAlbums: [String]? = nil
}

/// On-demand iTunes (600x600 artwork) + MusicBrainz (lazy artist metadata) lookups;
/// persistent positive/negative cache, per-host rate limiting, and bounded thumbnails.
actor ArtistPhotoStore {
    static let shared = ArtistPhotoStore()
    struct CacheEntry: Codable {
        var photo: ArtistPhoto?
        var checked: Date
        var retryAfter: Date? = nil
        var detailsChecked: Date? = nil
    }
    private static let cachedImageMinimumPixels = 600
    private static let allowedHosts: Set<String> = [
        "itunes.apple.com",
        "musicbrainz.org",
        "en.wikipedia.org",
        "upload.wikimedia.org",
        "thumb.wikimedia.org",
        "commons.wikimedia.org"
    ]
    static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return allowedHosts.contains(host) || host.hasSuffix(".mzstatic.com")
    }

    private let directory: URL
    private let session: URLSession
    private let preferences: UserDefaults
    private var completedDownloads = 0
    private var networkFailures: Set<String> = []
    private var jobs: [String: Task<ArtistPhoto?, Never>] = [:]
    private var detailJobs: [String: Task<ArtistPhoto?, Never>] = [:]
    private var lastRequestByBucket: [String: Date] = [:]
    private var requestingByBucket: [String: Bool] = [:]
    private var waitersByBucket: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(directory: URL? = nil, session: URLSession? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SoundBunkerArtists")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false; configuration.httpMaximumConnectionsPerHost = 2
        self.session = session ?? URLSession(configuration: configuration, delegate: ArtistRedirectPolicy(), delegateQueue: nil)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func photo(for artist: String, includeDetails: Bool = false) async -> ArtistPhoto? {
        guard artist != "Unknown Artist", !artist.isEmpty, artist.count <= 150 else { return nil }
        let key = SHA256.hash(data: Data(artist.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        let recordURL = directory.appendingPathComponent(key + ".json")
        var cachedEntry: CacheEntry?
        var cachedPhoto: ArtistPhoto?
        if let data = try? Data(contentsOf: recordURL), let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            cachedEntry = entry
            if var photo = entry.photo {
                photo.fileURL = directory.appendingPathComponent(key + ".jpg")
                if FileManager.default.fileExists(atPath: photo.fileURL.path) {
                    cachedPhoto = photo
                    let pixels = UIImage(contentsOfFile: photo.fileURL.path).map { max($0.size.width * $0.scale, $0.size.height * $0.scale) } ?? 0
                    let imageFresh = pixels >= CGFloat(Self.cachedImageMinimumPixels) || Date() < (entry.retryAfter ?? .distantPast)
                    if imageFresh {
                        let detailsFresh = entry.detailsChecked != nil && Date() < entry.detailsChecked!.addingTimeInterval(86_400)
                        if !includeDetails || detailsFresh {
                            return photo
                        }
                    }
                }
            }
            if entry.photo == nil, Date() < (entry.retryAfter ?? entry.checked.addingTimeInterval(86_400)) { return nil }
        }
        guard preferences.object(forKey: "artistPhotosEnabled") as? Bool ?? true else { return cachedPhoto }

        // Stage 1: Ensure we have the 600x600 artist image + base catalog info.
        var basePhoto = cachedPhoto
        let pixels = basePhoto.flatMap { UIImage(contentsOfFile: $0.fileURL.path) }.map { max($0.size.width * $0.scale, $0.size.height * $0.scale) } ?? 0
        if basePhoto == nil || pixels < CGFloat(Self.cachedImageMinimumPixels) {
            let job: Task<ArtistPhoto?, Never>
            if let existing = jobs[key] {
                job = existing
            } else {
                let created = Task { await self.lookupBasePhoto(artist, key: key, existing: cachedPhoto) }
                jobs[key] = created
                job = created
            }
            let fetched = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
            jobs[key] = nil
            let failed = networkFailures.remove(key) != nil
            basePhoto = fetched ?? cachedPhoto
            let retryAfter = fetched == nil ? Date().addingTimeInterval(failed ? 300 : 86_400) : nil
            if !job.isCancelled {
                let updatedEntry = CacheEntry(photo: basePhoto, checked: Date(), retryAfter: retryAfter, detailsChecked: cachedEntry?.detailsChecked)
                cachedEntry = updatedEntry
                if let data = try? JSONEncoder().encode(updatedEntry) { try? data.write(to: recordURL, options: .atomic) }
            }
        }

        guard includeDetails, var resolved = basePhoto else { return basePhoto }
        if resolved.summary != nil, cachedEntry?.detailsChecked != nil { return resolved }

        // Stage 2: Lazily enrich with MusicBrainz metadata only when opening the artist details page.
        let detailJob: Task<ArtistPhoto?, Never>
        if let existing = detailJobs[key] {
            detailJob = existing
        } else {
            let snapshot = resolved
            let created = Task { await self.enrichWithMusicBrainz(artist, base: snapshot, key: key) }
            detailJobs[key] = created
            detailJob = created
        }
        if let enriched = await withTaskCancellationHandler(operation: { await detailJob.value }, onCancel: { detailJob.cancel() }) {
            resolved = enriched
        }
        detailJobs[key] = nil
        if !detailJob.isCancelled {
            let updatedEntry = CacheEntry(photo: resolved, checked: cachedEntry?.checked ?? Date(), retryAfter: cachedEntry?.retryAfter, detailsChecked: Date())
            if let data = try? JSONEncoder().encode(updatedEntry) { try? data.write(to: recordURL, options: .atomic) }
        }
        return resolved
    }

    private func rateBucket(for host: String?) -> (name: String, interval: TimeInterval) {
        let host = (host ?? "").lowercased()
        if host.contains("musicbrainz.org") { return ("musicbrainz", 1.0) }
        if host.contains("itunes.apple.com") { return ("itunes", 0.25) }
        if host.hasSuffix(".mzstatic.com") { return ("cdn", 0.0) }
        return ("wikimedia", 0.8)
    }

    private func request(_ url: URL, maximumBytes: Int = 1_000_000) async throws -> Data {
        try Task.checkCancellation()
        guard preferences.object(forKey: "artistPhotosEnabled") as? Bool ?? true else { throw CancellationError() }
        guard url.scheme == "https", Self.isAllowedHost(url.host) else { throw URLError(.badURL) }
        let bucket = rateBucket(for: url.host)
        await acquireRequest(bucket: bucket.name)
        defer { releaseRequest(bucket: bucket.name) }
        try Task.checkCancellation()
        if bucket.interval > 0 {
            let delay = max(0, bucket.interval - Date().timeIntervalSince(lastRequestByBucket[bucket.name] ?? .distantPast))
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        try Task.checkCancellation()
        guard preferences.object(forKey: "artistPhotosEnabled") as? Bool ?? true else { throw CancellationError() }
        lastRequestByBucket[bucket.name] = Date()
        var request = URLRequest(url: url)
        request.setValue("Cassette/\(AppIdentity.version) (\(AppIdentity.projectURL.absoluteString))", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https", Self.isAllowedHost(response.url?.host) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private func acquireRequest(bucket: String) async {
        if requestingByBucket[bucket] == true {
            await withCheckedContinuation { continuation in
                waitersByBucket[bucket, default: []].append(continuation)
            }
        } else {
            requestingByBucket[bucket] = true
        }
    }

    private func releaseRequest(bucket: String) {
        if var waiters = waitersByBucket[bucket], !waiters.isEmpty {
            let next = waiters.removeFirst()
            waitersByBucket[bucket] = waiters
            next.resume()
        } else {
            requestingByBucket[bucket] = false
        }
    }

    static func apiURL(_ parameters: [String: String]) -> URL {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func itunesSearchURL(artist: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "term", value: artist)
        ]
        return components.url!
    }

    static func musicBrainzSearchURL(artist: String) -> URL {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "query", value: "artist:\"\(artist)\"")
        ]
        return components.url!
    }

    /// Upgrade an iTunes artwork URL (e.g. .../100x100bb.jpg) to 600x600bb.jpg.
    static func artworkURL600(from rawURL: String) -> URL? {
        let upgraded = rawURL.replacingOccurrences(
            of: #"/\d+x\d+[a-z]*\.(jpg|jpeg|png)$"#,
            with: "/600x600bb.$1",
            options: .regularExpression
        )
        guard let url = URL(string: upgraded), url.scheme == "https", isAllowedHost(url.host) else { return nil }
        return url
    }

    static func normalizeName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func match(_ pages: [[String: Any]], artist: String) -> [String: Any]? {
        let matches = pages.filter { page in
            let title = (page["title"] as? String ?? "").components(separatedBy: " (")[0]
            let description = (page["description"] as? String ?? "").lowercased()
            let qualifier = (page["title"] as? String ?? "").components(separatedBy: " (").dropFirst().joined().lowercased()
            guard !["film", "album", "song)", "discography", "tour", "soundtrack", "book", "episode"].contains(where: { qualifier.contains($0) }) else { return false }
            let musical = ["singer", "musician", "band", "rapper", "songwriter", "composer", "recording artist", "disc jockey", "dj", "duo", "trio", "pianist", "guitarist", "orchestra"].contains { description.contains($0) }
            let musicGroup = description.contains("group") && ["music", "rock", "pop", "jazz", "folk", "electronic", "metal", "hip hop"].contains { description.contains($0) }
            return normalizeName(title) == normalizeName(artist) && (musical || musicGroup)
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func synthesizeSummary(
        artist: String,
        artistType: String?,
        origin: String?,
        lifeSpan: String?,
        disambiguation: String?,
        genre: String?,
        tags: [String],
        topAlbums: [String]
    ) -> String? {
        var sentences: [String] = []
        let cleanDisambiguation = disambiguation?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let cleanGenre = genre?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let cleanOrigin = origin?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let cleanType = artistType?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        let roleDescriptor: String = {
            if let disambig = cleanDisambiguation {
                return disambig
            }
            let typeWord: String
            switch cleanType?.lowercased() {
            case "group": typeWord = "musical group"
            case "person": typeWord = "recording artist"
            case "orchestra": typeWord = "orchestra"
            case "choir": typeWord = "choir"
            case .some(let other): typeWord = other.lowercased()
            case nil: typeWord = "recording artist"
            }
            if let cleanGenre = cleanGenre {
                return "\(cleanGenre.lowercased()) \(typeWord)"
            }
            return typeWord
        }()

        let article = ["a", "e", "i", "o", "u"].contains(String(roleDescriptor.prefix(1)).lowercased()) ? "an" : "a"
        var firstSentence = "\(artist) is \(article) \(roleDescriptor)"
        if let cleanOrigin = cleanOrigin {
            firstSentence += " from \(cleanOrigin)"
        }
        if let lifeSpan = lifeSpan?.nonEmpty {
            let verb = (cleanType?.lowercased() == "group") ? "formed in" : "active across"
            if lifeSpan.contains("–") {
                firstSentence += " (\(lifeSpan))"
            } else {
                firstSentence += ", \(verb) \(lifeSpan)"
            }
        }
        firstSentence += "."
        sentences.append(firstSentence)

        let styleItems = ([cleanGenre].compactMap { $0 } + tags)
            .reduce(into: [String]()) { acc, item in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !acc.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
                acc.append(trimmed)
            }
        if styleItems.count > 1 {
            let styles = styleItems.prefix(4).joined(separator: ", ")
            sentences.append("Associated styles and genres include \(styles).")
        }
        if !topAlbums.isEmpty {
            let releases = topAlbums.prefix(4).joined(separator: ", ")
            sentences.append("Notable releases in catalog include \(releases).")
        }
        guard !sentences.isEmpty, (cleanDisambiguation != nil || cleanOrigin != nil || cleanGenre != nil || !tags.isEmpty || !topAlbums.isEmpty) else {
            return nil
        }
        return sentences.joined(separator: " ")
    }

    private func lookupBasePhoto(_ artist: String, key: String, existing: ArtistPhoto?) async -> ArtistPhoto? {
        // 1. Try iTunes Search API for 600x600 artwork + genre/album metadata
        if let itunesPhoto = await lookupITunes(artist, key: key, existing: existing) {
            return itunesPhoto
        }
        // 2. Fallback to Wikimedia if iTunes had no match (preserves compatibility and offline resilience)
        return await lookupWikimedia(artist, key: key, existing: existing)
    }

    private func lookupITunes(_ artist: String, key: String, existing: ArtistPhoto?) async -> ArtistPhoto? {
        do {
            let searchURL = Self.itunesSearchURL(artist: artist)
            let payload = try JSONSerialization.jsonObject(with: await request(searchURL)) as? [String: Any]
            guard let results = payload?["results"] as? [[String: Any]], !results.isEmpty else { return nil }
            let target = Self.normalizeName(artist)
            let matched = results.filter { item in
                guard let name = item["artistName"] as? String else { return false }
                return Self.normalizeName(name) == target
            }
            guard let primary = matched.first,
                  let rawArtwork = (primary["artworkUrl100"] as? String) ?? (primary["artworkUrl60"] as? String),
                  let imageURL = Self.artworkURL600(from: rawArtwork) else { return nil }

            let genre = matched.compactMap { $0["primaryGenreName"] as? String }.first { !$0.isEmpty }
            var albums: [String] = []
            var years: [Int] = []
            for item in matched {
                if let collection = item["collectionName"] as? String, !collection.isEmpty,
                   !albums.contains(where: { $0.caseInsensitiveCompare(collection) == .orderedSame }) {
                    albums.append(collection)
                }
                if let releaseDate = item["releaseDate"] as? String, releaseDate.count >= 4,
                   let year = Int(releaseDate.prefix(4)) {
                    years.append(year)
                }
            }
            let span: String? = {
                guard let minYear = years.min(), let maxYear = years.max() else { return nil }
                return minYear == maxYear ? "\(minYear)" : "\(minYear)–\(maxYear)"
            }()
            let sourceString = (primary["artistViewUrl"] as? String) ?? (primary["collectionViewUrl"] as? String) ?? "https://itunes.apple.com"
            var sourceComponents = URLComponents(string: sourceString)
            if sourceComponents?.scheme == "http" { sourceComponents?.scheme = "https" }
            let sourceURL = sourceComponents?.url ?? URL(string: "https://itunes.apple.com")!

            let imageData = try await request(imageURL, maximumBytes: 3_000_000)
            guard let fileURL = try saveThumbnail(data: imageData, key: key, maxPixelSize: 600) else { return nil }
            let initialSummary = existing?.summary ?? Self.synthesizeSummary(
                artist: artist,
                artistType: existing?.artistType,
                origin: existing?.origin,
                lifeSpan: existing?.lifeSpan ?? span,
                disambiguation: nil,
                genre: genre,
                tags: existing?.tags ?? [],
                topAlbums: Array(albums.prefix(4))
            )
            return ArtistPhoto(
                filename: imageURL.lastPathComponent,
                creator: (primary["artistName"] as? String) ?? artist,
                license: "Apple Music / iTunes Artwork",
                licenseURL: sourceURL,
                sourceURL: sourceURL,
                fileURL: fileURL,
                summary: initialSummary,
                genre: genre ?? existing?.genre,
                origin: existing?.origin,
                lifeSpan: existing?.lifeSpan ?? span,
                artistType: existing?.artistType,
                tags: existing?.tags,
                topAlbums: albums.isEmpty ? existing?.topAlbums : Array(albums.prefix(4))
            )
        } catch {
            networkFailures.insert(key)
            return nil
        }
    }

    private func lookupWikimedia(_ artist: String, key: String, existing: ArtistPhoto?) async -> ArtistPhoto? {
        do {
            let searchURL = Self.apiURL(["action":"query", "generator":"search", "gsrsearch":artist, "gsrlimit":"3", "gsrnamespace":"0", "prop":"pageimages|description", "piprop":"name", "pilicense":"free", "format":"json", "formatversion":"2"])
            let search = try JSONSerialization.jsonObject(with: await request(searchURL)) as? [String: Any]
            guard let query = search?["query"] as? [String: Any], let pages = query["pages"] as? [[String: Any]],
                  let page = Self.match(pages, artist: artist), let filename = page["pageimage"] as? String else { return nil }
            let pageDescription = (page["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let infoURL = Self.apiURL(["action":"query", "titles":"File:" + filename, "prop":"imageinfo", "iiprop":"url|extmetadata", "iiurlwidth":"600", "format":"json", "formatversion":"2"])
            let info = try JSONSerialization.jsonObject(with: await request(infoURL)) as? [String: Any]
            let imageQuery = info?["query"] as? [String: Any]
            let imagePages = imageQuery?["pages"] as? [[String: Any]]
            guard let imageInfo = (imagePages?.first?["imageinfo"] as? [[String: Any]])?.first,
                  let thumbnail = imageInfo["thumburl"] as? String, let imageURL = URL(string: thumbnail), ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(imageURL.host ?? ""),
                  let descriptionURL = imageInfo["descriptionurl"] as? String, let sourceURL = URL(string: descriptionURL),
                  sourceURL.scheme == "https", ["commons.wikimedia.org", "en.wikipedia.org"].contains(sourceURL.host ?? ""),
                  let metadata = imageInfo["extmetadata"] as? [String: Any],
                  let creator = (metadata["Artist"] as? [String: Any])?["value"] as? String,
                  let license = (metadata["LicenseShortName"] as? [String: Any])?["value"] as? String else { return nil }
            var licenseComponents = URLComponents(string: ((metadata["LicenseUrl"] as? [String: Any])?["value"] as? String) ?? sourceURL.absoluteString)
            if licenseComponents?.scheme == "http" { licenseComponents?.scheme = "https" }
            let licenseURL = licenseComponents?.url ?? sourceURL
            guard licenseURL.scheme == "https" else { return nil }
            let data = try await request(imageURL, maximumBytes: 2_000_000)
            guard let fileURL = try saveThumbnail(data: data, key: key, maxPixelSize: 600) else { return nil }
            let summary = existing?.summary ?? Self.synthesizeSummary(
                artist: artist,
                artistType: existing?.artistType,
                origin: existing?.origin,
                lifeSpan: existing?.lifeSpan,
                disambiguation: pageDescription,
                genre: existing?.genre,
                tags: existing?.tags ?? [],
                topAlbums: existing?.topAlbums ?? []
            )
            return ArtistPhoto(
                filename: filename,
                creator: Self.plain(creator),
                license: Self.plain(license),
                licenseURL: licenseURL,
                sourceURL: sourceURL,
                fileURL: fileURL,
                summary: summary,
                genre: existing?.genre,
                origin: existing?.origin,
                lifeSpan: existing?.lifeSpan,
                artistType: existing?.artistType,
                tags: existing?.tags,
                topAlbums: existing?.topAlbums
            )
        } catch {
            networkFailures.insert(key)
            return nil
        }
    }

    private func enrichWithMusicBrainz(_ artist: String, base: ArtistPhoto, key: String) async -> ArtistPhoto? {
        do {
            let url = Self.musicBrainzSearchURL(artist: artist)
            let payload = try JSONSerialization.jsonObject(with: await request(url)) as? [String: Any]
            guard let artists = payload?["artists"] as? [[String: Any]], !artists.isEmpty else { return base }
            let target = Self.normalizeName(artist)
            guard let matched = artists.first(where: { ($0["name"] as? String).map(Self.normalizeName) == target }) ?? artists.first else {
                return base
            }
            let artistType = (matched["type"] as? String)?.nonEmpty ?? base.artistType
            let disambiguation = (matched["disambiguation"] as? String)?.nonEmpty
            let beginArea = ((matched["begin-area"] as? [String: Any])?["name"] as? String)?.nonEmpty
            let area = ((matched["area"] as? [String: Any])?["name"] as? String)?.nonEmpty
            let country = (matched["country"] as? String)?.nonEmpty
            let origin: String? = {
                if let beginArea = beginArea, let area = area, beginArea.caseInsensitiveCompare(area) != .orderedSame {
                    return "\(beginArea), \(area)"
                }
                return beginArea ?? area ?? country ?? base.origin
            }()
            let lifeSpan: String? = {
                guard let span = matched["life-span"] as? [String: Any] else { return base.lifeSpan }
                let begin = (span["begin"] as? String)?.prefix(4).description.nonEmpty
                let end = (span["end"] as? String)?.prefix(4).description.nonEmpty
                let ended = (span["ended"] as? Bool) ?? false
                if let begin = begin, let end = end { return "\(begin)–\(end)" }
                if let begin = begin { return ended ? begin : "\(begin)–Present" }
                return base.lifeSpan
            }()
            let rawTags = (matched["tags"] as? [[String: Any]]) ?? []
            let sortedTags = rawTags
                .sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
                .compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            let topTags = Array(sortedTags.prefix(5))
            let genre = base.genre ?? topTags.first?.capitalized

            var updated = base
            updated.artistType = artistType
            updated.origin = origin
            updated.lifeSpan = lifeSpan
            updated.genre = genre
            if !topTags.isEmpty { updated.tags = topTags }
            if let summary = Self.synthesizeSummary(
                artist: artist,
                artistType: artistType,
                origin: origin,
                lifeSpan: lifeSpan,
                disambiguation: disambiguation,
                genre: genre,
                tags: topTags,
                topAlbums: updated.topAlbums ?? []
            ) {
                updated.summary = summary
            }
            return updated
        } catch {
            return base
        }
    }

    private func saveThumbnail(data: Data, key: String, maxPixelSize: Int) throws -> URL? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnailImage).jpegData(compressionQuality: 0.82) else { return nil }
        let fileURL = directory.appendingPathComponent(key + ".jpg")
        try jpeg.write(to: fileURL, options: .atomic)
        completedDownloads += 1
        if completedDownloads.isMultiple(of: 20) { trimCache() }
        return fileURL
    }

    private func trimCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var bytes = 0
        for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes > 15_000_000 { try? FileManager.default.removeItem(at: file) }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private final class ArtistRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && ArtistPhotoStore.isAllowedHost(request.url?.host)
        completionHandler(allowed ? request : nil)
    }
}
