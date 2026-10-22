import AVFoundation
import CryptoKit
import MediaPlayer
import UIKit
import ImageIO

struct AppleMusicTrackItem: Sendable {
    var persistentID: UInt64
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var duration: Double
    var trackNumber: Int
    var discNumber: Int
    var assetURL: URL?
    var isCloudItem: Bool = false
    var hasProtectedAsset: Bool = false
    var lyrics: String? = nil
    var artworkData: (@Sendable () -> Data?)? = nil
}

protocol AppleMusicLibraryProviding: Sendable {
    func authorizationStatus() -> MPMediaLibraryAuthorizationStatus
    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus
    func fetchTracks() -> [AppleMusicTrackItem]
}

struct SystemAppleMusicLibrary: AppleMusicLibraryProviding {
    func authorizationStatus() -> MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchTracks() -> [AppleMusicTrackItem] {
        guard let items = MPMediaQuery.songs().items else { return [] }
        return items.map { item in
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumArtist = item.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = item.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let genre = item.genre?.trimmingCharacters(in: .whitespacesAndNewlines)
            let artwork = item.artwork
            let resolvedArtist = (artist?.isEmpty == false ? artist! : "Unknown Artist")
            return AppleMusicTrackItem(
                persistentID: item.persistentID,
                title: (title?.isEmpty == false ? title! : "Unknown Title"),
                artist: resolvedArtist,
                albumArtist: (albumArtist?.isEmpty == false ? albumArtist! : resolvedArtist),
                album: (album?.isEmpty == false ? album! : "Unknown Album"),
                genre: (genre?.isEmpty == false ? genre! : "Unknown Genre"),
                duration: item.playbackDuration.isFinite && item.playbackDuration > 0 ? item.playbackDuration : 0,
                trackNumber: item.albumTrackNumber,
                discNumber: item.discNumber,
                assetURL: item.assetURL,
                isCloudItem: item.isCloudItem,
                hasProtectedAsset: item.hasProtectedAsset,
                lyrics: item.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.lyrics : nil,
                artworkData: artwork.map { mediaArtwork in
                    { mediaArtwork.image(at: CGSize(width: 320, height: 320))?.jpegData(compressionQuality: 0.8) }
                }
            )
        }
    }
}

struct ScanResult {
    var tracks: [Track]
    var seen: Set<String>
    var skipped: Int
    var issues: [String]
    var playlists: [ScannedPlaylist] = []
    var complete = true
    var directories: [DirectoryStamp] = []
    var directoryCheckReliable = true
}

enum LocalFilePolicy {
    static func musicFile(_ relativePath: String, in root: URL) throws -> URL {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        // Derive the file URL from `root` directly so any security-scoped sandbox extension attached to `root` is inherited.
        let file = root.appendingPathComponent(relativePath)
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard !relativePath.hasPrefix("/"), resolved.path.hasPrefix(canonicalRoot.path + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        try check(file)
        return file
    }

    static func check(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let basic = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard basic.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        if basic.isDirectory == true { return }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded {
            throw NSError(domain: "PocketMusic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cloud-only file skipped. Download it in Files before adding it."])
        }

    }
}

/// Saved only after a complete scan. Folder checks never enumerate/open audio files.
struct DirectoryStamp: Codable, Equatable {
    var path: String
    var modified: Date
    var identity: String
    static func read(root: URL, path: String) throws -> DirectoryStamp {
        let url = path.isEmpty ? root : try LocalFilePolicy.musicFile(path, in: root)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let modified = values.contentModificationDate, let identity = values.fileResourceIdentifier else { throw CocoaError(.fileReadUnknown) }
        return DirectoryStamp(path: path, modified: modified, identity: String(describing: identity))
    }
}
struct ScanCheckpoint: Codable {
    var sourceID: UUID
    var excludedPaths: [String]
    var directories: [DirectoryStamp]
}

actor LibraryScanner {
    private var manifestCache: [String: (fingerprint: String, result: M3UParseResult)] = [:]
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "alac", "wav", "aiff", "aif", "flac", "ogg", "opus"]
    func directoriesChanged(root: URL, checkpoint: ScanCheckpoint) throws -> Bool {
        guard !checkpoint.directories.isEmpty else { return true }
        for previous in checkpoint.directories {
            try Task.checkCancellation()
            guard let current = try? DirectoryStamp.read(root: root, path: previous.path), current == previous else { return true }
        }
        return false
    }
    func scan(root: URL, sourceID: UUID, existing: [String: Track], cache: URL, excluded: [String] = [],
              checked: @escaping @Sendable (Int) async -> Void = { _ in },
              progress: @escaping @Sendable ([Track], Int) async -> Void) async throws -> ScanResult {
        try LocalFilePolicy.check(root)
        // POSIX isReadableFile and uncoordinated URLs can reject provider-backed folders (like On My iPod → Music).
        // Coordinate directory access while the selected security scope is held, and enumerate using the coordinated URL
        // so child file URLs inherit the active security-scoped sandbox token on iOS.
        var coordinationError: NSError?, directoryError: Error?
        var activeRoot = root
        NSFileCoordinator().coordinate(readingItemAt: root, options: .withoutChanges, error: &coordinationError) { coordinatedRoot in
            do {
                _ = try FileManager.default.contentsOfDirectory(at: coordinatedRoot, includingPropertiesForKeys: nil)
                activeRoot = coordinatedRoot
            } catch { directoryError = error }
        }
        if let error = coordinationError ?? (directoryError as NSError?) { throw error }
        let scanRoot = activeRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootStamp = try? DirectoryStamp.read(root: activeRoot, path: "")
        var directories = rootStamp.map { [$0] } ?? []
        var directoryCheckReliable = rootStamp != nil
        var issues: [String] = []
        var complete = true
        guard let enumerator = FileManager.default.enumerator(at: activeRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .volumeIdentifierKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                complete = false
                if issues.count < 20 { issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }; return true
            }) else { throw CocoaError(.fileReadUnknown) }
        var playlists: [ScannedPlaylist] = []
        var tracks: [Track] = [], batch: [Track] = [], seen = Set<String>(), skipped = 0, count = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while let file = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let previousCount = count
            do {
                let relativePath = Self.relativePath(of: file, under: activeRoot, canonicalRoot: scanRoot)
                if excluded.contains(where: { relativePath == $0 || relativePath.hasPrefix($0 + "/") }) { enumerator.skipDescendants(); continue }
                let attributes = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .volumeIdentifierKey, .fileSizeKey, .contentModificationDateKey])
                if attributes.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if attributes.isDirectory == true {
                    if let stamp = try? DirectoryStamp.read(root: activeRoot, path: relativePath) { directories.append(stamp) }
                    else { directoryCheckReliable = false }
                    continue
                }
                guard attributes.isRegularFile == true else { continue }
                if ["m3u", "m3u8"].contains(file.pathExtension.lowercased()) {
                    try LocalFilePolicy.check(file)
                    guard (attributes.fileSize ?? 0) <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    let fingerprint = "\(attributes.fileSize ?? 0):\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                    let key = scanRoot.path + ":" + relativePath
                    let parsed: M3UParseResult
                    if let cached = manifestCache[key], cached.fingerprint == fingerprint { parsed = cached.result }
                    else {
                        parsed = try M3UParser.parse(Data(contentsOf: file), playlist: file, root: scanRoot)
                        if manifestCache.count > 500 { manifestCache.removeAll(keepingCapacity: true) }
                        manifestCache[key] = (fingerprint, parsed)
                    }
                    playlists.append(ScannedPlaylist(path: relativePath, name: file.deletingPathExtension().lastPathComponent, entries: parsed.entries))
                    issues.append(contentsOf: parsed.issues.prefix(max(0, 20 - issues.count)))
                    continue
                }
                guard Self.extensions.contains(file.pathExtension.lowercased()) else { continue }
                count += 1
                try LocalFilePolicy.check(file)
                let relative = relativePath
                let identity = Self.trackIdentity(for: file, attributes: attributes, sourceID: sourceID, relativePath: relative, existing: existing)
                var fingerprint = "\(attributes.fileSize ?? 0):\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                let sidecar = file.deletingPathExtension().appendingPathExtension("lrc")
                if let lyricAttributes = try? sidecar.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    fingerprint += ":lrc:\(lyricAttributes.fileSize ?? 0):\(lyricAttributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                }
                var track: Track
                let artworkExists = existing[identity]?.artwork.map { FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path) } ?? true
                if let previous = existing[identity], previous.fingerprint == fingerprint, previous.audioFormat != nil, artworkExists { track = previous }
                else {
                    track = try await metadata(file, id: identity, fingerprint: fingerprint, cache: cache)
                    if let previous = existing[identity] { track.added = previous.added; track.favorite = previous.favorite; track.locations = previous.locations }
                }
                let location = TrackLocation(sourceID: sourceID, relativePath: relative, available: true)
                if let index = track.locations.firstIndex(where: { $0.sourceID == sourceID }) { track.locations[index] = location }
                else { track.locations.append(location) }
                seen.insert(identity)
                tracks.append(track)
                if existing[identity] != track { batch.append(track) }
                if batch.count == 25 { await progress(batch, count); batch.removeAll() }
            } catch is CancellationError { throw CancellationError() }
            catch { complete = false; skipped += 1; if issues.count < 20 { issues.append("\(file.lastPathComponent): \(error.localizedDescription)") } }
            if count > previousCount && ProcessInfo.processInfo.systemUptime - lastProgress >= 0.25 {
                await checked(count); lastProgress = ProcessInfo.processInfo.systemUptime
            }
        }
        if !batch.isEmpty { await progress(batch, count) }
        await checked(count)
        return ScanResult(tracks: tracks, seen: seen, skipped: skipped, issues: issues, playlists: playlists, complete: complete, directories: directories, directoryCheckReliable: directoryCheckReliable)
    }

    private static func relativePath(of file: URL, under root: URL, canonicalRoot: URL) -> String {
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedFile.hasPrefix(canonicalRoot.path + "/") {
            return String(resolvedFile.dropFirst(canonicalRoot.path.count + 1))
        }
        let standardRoot = root.standardizedFileURL.path
        let standardFile = file.standardizedFileURL.path
        if standardFile.hasPrefix(standardRoot + "/") {
            return String(standardFile.dropFirst(standardRoot.count + 1))
        }
        return String(resolvedFile.dropFirst(canonicalRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Reuses an existing track identity for the same `(sourceID, relativePath)` if a File Provider rotated its transient resource identifier,
    /// and collapses duplicate copies when the exact same audio bytes exist in both Cassette's folder and a selected folder.
    private static func trackIdentity(for file: URL, attributes: URLResourceValues, sourceID: UUID, relativePath: String, existing: [String: Track]) -> String {
        let hardwareID: String
        if let fid = attributes.fileResourceIdentifier, let volume = attributes.volumeIdentifier {
            hardwareID = "\(volume):\(fid)"
        } else {
            hardwareID = file.resolvingSymlinksInPath().standardizedFileURL.path
        }
        if existing[hardwareID] != nil { return hardwareID }
        // If this exact (sourceID, relativePath) was previously indexed under an older provider resource ID, preserve its identity instead of creating a duplicate row.
        if let match = existing.values.first(where: { $0.locations.contains(where: { $0.sourceID == sourceID && $0.relativePath == relativePath }) }) {
            return match.id
        }
        return hardwareID
    }

    private func metadata(_ url: URL, id: String, fingerprint: String, cache: URL) async throws -> Track {
        var readError: NSError?
        var asset: AVURLAsset?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &readError) { coordinatedURL in
            asset = AVURLAsset(url: coordinatedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        }
        if let error = readError { throw error }
        guard let asset = asset else { throw CocoaError(.fileReadUnknown) }
        var duration = (try? await asset.load(.duration).seconds) ?? 0
        let items = (try? await asset.load(.metadata)) ?? []
        if !duration.isFinite || duration <= 0, let audio = try? AVAudioFile(forReading: url) {
            duration = Double(audio.length) / audio.processingFormat.sampleRate
        }
        var format = url.pathExtension.uppercased()
        var bitrate: Int?
        var stream: AudioStreamBasicDescription?
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            if let rate = try? await audioTrack.load(.estimatedDataRate), rate.isFinite && rate > 0 { bitrate = Int(rate.rounded()) }
            if let descriptions = try? await audioTrack.load(.formatDescriptions), let description = descriptions.first {
                stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            }
        }
        // Some native WAV/AIFF decoders expose no AVAsset audio track on Catalyst.
        // AudioToolbox reads the encoded file header without decoding the song or including cover bytes in bitrate.
        if stream == nil || bitrate == nil {
            var file: AudioFileID?
            if AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file = file {
                defer { AudioFileClose(file) }
                if stream == nil {
                    var description = AudioStreamBasicDescription()
                    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    if AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &description) == noErr { stream = description }
                }
                if bitrate == nil {
                    var rate: UInt32 = 0
                    var size = UInt32(MemoryLayout<UInt32>.size)
                    if AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &rate) == noErr, rate > 0 { bitrate = Int(rate) }
                }
            }
        }
        if let stream = stream {
            switch stream.mFormatID {
            case kAudioFormatMPEGLayer3: format = "MP3"
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: format = "AAC"
            case kAudioFormatAppleLossless: format = "ALAC"
            case kAudioFormatLinearPCM:
                format = "\(url.pathExtension.uppercased()) / PCM"
                if bitrate == nil && stream.mSampleRate.isFinite && stream.mSampleRate > 0 && stream.mBytesPerFrame > 0 {
                    bitrate = Int(stream.mSampleRate * Double(stream.mBytesPerFrame) * 8)
                }
            case kAudioFormatFLAC: format = "FLAC"
            case kAudioFormatOpus: format = "Opus"
            default: break
            }
        }
        func value(_ key: AVMetadataKey) -> String? {
            let values = items
                .filter { $0.commonKey == key }
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return values.isEmpty ? nil : values.joined(separator: "; ")
        }
        func tag(_ fragments: [String]) -> String? {
            items.first { item in fragments.contains { (item.identifier?.rawValue ?? String(describing: item.key)).localizedCaseInsensitiveContains($0) } }?.stringValue
        }
        let title = value(.commonKeyTitle).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let artist = value(.commonKeyArtist) ?? "Unknown Artist"
        let album = value(.commonKeyAlbumName) ?? "Unknown Album"
        var artwork: String?
        if let data = await Self.extractArtworkData(from: asset, preloadedItems: items) {
            artwork = try? Self.writeThumbnail(from: data, to: cache)
        }
        var lyrics = tag(["USLT", "lyrics"])
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        if FileManager.default.fileExists(atPath: lrc.path), (try? LocalFilePolicy.check(lrc)) != nil {
            let size = try lrc.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size < 1_000_000 { lyrics = try? String(contentsOf: lrc, encoding: .utf8) }
        }
        return Track(id: id, title: title, artist: artist, albumArtist: tag(["albumArtist", "TPE2", "aART"]) ?? artist,
                     album: album, genre: tag(["genre", "TCON"]) ?? "Unknown Genre", duration: duration.isFinite ? duration : 0,
                     trackNumber: Int((tag(["trackNumber", "TRCK"]) ?? "0").components(separatedBy: "/")[0]) ?? 0,
                     discNumber: Int((tag(["discNumber", "TPOS"]) ?? "0").components(separatedBy: "/")[0]) ?? 0,
                     fingerprint: fingerprint, artwork: artwork, lyrics: lyrics, locations: [], added: Date(), audioFormat: format, bitrate: bitrate)
    }

    func scanAppleMusic(items: [AppleMusicTrackItem], sourceID: UUID, existing: [String: Track], cache: URL,
                        checked: @escaping @Sendable (Int) async -> Void = { _ in },
                        progress: @escaping @Sendable ([Track], Int) async -> Void) async throws -> ScanResult {
        var tracks: [Track] = []
        var batch: [Track] = []
        var seen = Set<String>()
        var skipped = 0
        var count = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime

        for item in items {
            try Task.checkCancellation()
            guard !item.hasProtectedAsset, let assetURL = item.assetURL,
                  assetURL.isFileURL || assetURL.scheme?.lowercased() == "ipod-library" else {
                skipped += 1
                continue
            }
            count += 1
            let identity = "apple-music:\(item.persistentID)"
            let relative = assetURL.isFileURL ? assetURL.path : assetURL.absoluteString
            let fingerprint = "\(item.persistentID):\(item.title):\(item.artist):\(item.album):\(Int(item.duration.rounded())):\(relative)"
            var track: Track
            let artworkExists = existing[identity]?.artwork.map { FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path) } ?? true
            if let previous = existing[identity], previous.fingerprint == fingerprint, previous.audioFormat != nil, artworkExists {
                track = previous
            } else {
                var artwork: String? = artworkExists ? existing[identity]?.artwork : nil
                if artwork == nil, let data = item.artworkData?(), !data.isEmpty {
                    artwork = try? Self.writeThumbnail(from: data, to: cache)
                }
                let ext = assetURL.pathExtension.uppercased()
                var format = ext.isEmpty ? "Apple Music" : ext
                var bitrate: Int?
                let asset = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                if artwork == nil, let data = await Self.extractArtworkData(from: asset) {
                    artwork = try? Self.writeThumbnail(from: data, to: cache)
                }
                if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                    if let rate = try? await audioTrack.load(.estimatedDataRate), rate.isFinite && rate > 0 {
                        bitrate = Int(rate.rounded())
                    }
                    if let descriptions = try? await audioTrack.load(.formatDescriptions),
                       let description = descriptions.first,
                       let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        switch stream.mFormatID {
                        case kAudioFormatMPEGLayer3: format = "MP3"
                        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: format = "AAC"
                        case kAudioFormatAppleLossless: format = "ALAC"
                        case kAudioFormatLinearPCM: format = "\(ext.isEmpty ? "WAV" : ext) / PCM"
                        case kAudioFormatFLAC: format = "FLAC"
                        case kAudioFormatOpus: format = "Opus"
                        default: break
                        }
                    }
                }
                var duration = item.duration
                if (!duration.isFinite || duration <= 0), let loaded = try? await asset.load(.duration).seconds, loaded.isFinite && loaded > 0 {
                    duration = loaded
                }
                track = Track(
                    id: identity,
                    title: item.title,
                    artist: item.artist,
                    albumArtist: item.albumArtist,
                    album: item.album,
                    genre: item.genre,
                    duration: duration.isFinite ? duration : 0,
                    trackNumber: item.trackNumber,
                    discNumber: item.discNumber,
                    fingerprint: fingerprint,
                    artwork: artwork,
                    lyrics: item.lyrics,
                    locations: existing[identity]?.locations ?? [],
                    added: existing[identity]?.added ?? Date(),
                    favorite: existing[identity]?.favorite ?? false,
                    audioFormat: format,
                    bitrate: bitrate
                )
            }
            let location = TrackLocation(sourceID: sourceID, relativePath: relative, available: true)
            if let index = track.locations.firstIndex(where: { $0.sourceID == sourceID }) {
                track.locations[index] = location
            } else {
                track.locations.append(location)
            }
            seen.insert(identity)
            tracks.append(track)
            if existing[identity] != track { batch.append(track) }
            if batch.count == 25 { await progress(batch, count); batch.removeAll() }
            if ProcessInfo.processInfo.systemUptime - lastProgress >= 0.25 {
                await checked(count)
                lastProgress = ProcessInfo.processInfo.systemUptime
            }
        }
        if !batch.isEmpty { await progress(batch, count) }
        await checked(count)
        return ScanResult(tracks: tracks, seen: seen, skipped: skipped, issues: [], playlists: [], complete: true, directories: [], directoryCheckReliable: false)
    }

    static func writeThumbnail(from data: Data, to cache: URL) throws -> String? {
        guard !data.isEmpty, data.count < 25_000_000 else { return nil }
        let digest = SHA256.hash(data: data)
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let name = hex + ".jpg"
        let destination = cache.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return name
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let jpg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else { return nil }
        try jpg.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return name
    }

    private static func extractArtworkData(from asset: AVURLAsset, preloadedItems: [AVMetadataItem]? = nil) async -> Data? {
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let allItems: [AVMetadataItem]
        if let preloadedItems = preloadedItems {
            allItems = common + preloadedItems
        } else {
            let metadata = (try? await asset.load(.metadata)) ?? []
            allItems = common + metadata
        }
        for item in allItems {
            let isArtwork = item.commonKey == .commonKeyArtwork
                || item.identifier == .commonIdentifierArtwork
                || item.identifier == .id3MetadataAttachedPicture
                || item.identifier == .iTunesMetadataCoverArt
                || (item.key as? String)?.uppercased().contains("PIC") == true
                || (item.key as? String)?.lowercased().contains("covr") == true
            guard isArtwork else { continue }
            if let data = (try? await item.load(.dataValue)) ?? item.dataValue, !data.isEmpty {
                return data
            }
            if let value = (try? await item.load(.value)) ?? item.value {
                if let data = value as? Data, !data.isEmpty { return data }
                if let dict = value as? NSDictionary, let data = dict["data"] as? Data, !data.isEmpty { return data }
            }
        }
        return nil
    }

    func extractArtwork(from url: URL, cache: URL) async -> String? {
        var asset: AVURLAsset?
        if url.scheme?.lowercased() == "ipod-library" {
            asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        } else {
            var readError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &readError) { coordinatedURL in
                asset = AVURLAsset(url: coordinatedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            }
            if readError != nil { return nil }
        }
        guard let asset = asset, let data = await Self.extractArtworkData(from: asset) else { return nil }
        return try? Self.writeThumbnail(from: data, to: cache)
    }
}
