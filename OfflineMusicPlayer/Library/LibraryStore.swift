import Foundation
import Combine
import MediaPlayer

@MainActor
final class LibraryStore: ObservableObject {
    static let appleMusicSourceID = UUID(uuidString: "A11E0000-0000-4000-8000-00000000A11E")!
    static let artworkCacheLimitBytes = 200_000_000

    @Published private(set) var tracks: [Track] = [] {
        didSet { trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }); visibleCache = nil; sortedCache = nil; browseCache = nil; historyCache = nil }
    }
    @Published private(set) var sources: [MusicSource] = [] { didSet { visibleCache = nil; sortedCache = nil; browseCache = nil; historyCache = nil } }
    @Published private(set) var appleMusicEnabled = false { didSet { visibleCache = nil; sortedCache = nil; browseCache = nil; historyCache = nil } }
    @Published private(set) var playbackHistory: [PlaybackHistoryEntry] = [] { didSet { historyCache = nil } }
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var scanning = false
    @Published private(set) var clearingArtwork = false
    @Published private(set) var artworkRevision = 0
    var busy: Bool { scanning || clearingArtwork }
    @Published private(set) var scannedCount = 0
    @Published private(set) var scanStatus = ""
    @Published var errorMessage: String?
    @Published var pickerRequest: PickerRequest?
    let documents: URL
    let artworkDirectory: URL
    private(set) var database: LibraryDatabase?
    private let scanner = LibraryScanner()
    private let appleMusicProvider: AppleMusicLibraryProviding
    private var scanTask: Task<Void, Never>?
    private var trackLookup: [String: Track] = [:]
    private var visibleCache: [Track]?
    private var sortedCache: [Track]?
    private var browseCache: BrowseIndex?
    private var historyCache: [PlayedSong]?
    private var artworkNeedsTrim = false
    private var artworkRestoreInFlight = Set<String>()
    private var lastScan = Date.distantPast
    private var checkpoints: [UUID: ScanCheckpoint] = [:]
    private var discoveryStarted = false
    private var discoveryTask: Task<Void, Never>?
    private var pendingAutomaticSources = Set<UUID>()
    private var automaticSources = Set<UUID>()
    private var playbackActive = false
    private var sceneActive = true
    @Published private(set) var checkingFolders = false
    private(set) var scanRunCount = 0
    private var resolvedRoots: [UUID: URL] = [:]
    private enum FolderChange { case add(MusicSource, FolderAccess), remove(UUID) }
    private var folderChanges: [FolderChange] = []
    private var firstScanGrants: [UUID: FolderAccess] = [:]

    init(documents: URL? = nil, inMemory: Bool = false, databaseURL: URL? = nil, appleMusicProvider: AppleMusicLibraryProviding = SystemAppleMusicLibrary()) {
        self.appleMusicProvider = appleMusicProvider
        let fm = FileManager.default
        #if targetEnvironment(macCatalyst)
        // Catalyst preview is app-specific even when launched with an ad-hoc signature without sandbox entitlements.
        let defaultDocuments = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PocketMusic/Files", isDirectory: true)
        #else
        let defaultDocuments = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        self.documents = documents ?? defaultDocuments
        artworkDirectory = documents.map { $0.appendingPathComponent(".artwork", isDirectory: true) } ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PocketMusicArtwork", isDirectory: true)
        do {
            try fm.createDirectory(at: self.documents, withIntermediateDirectories: true)
            // Files may hide an empty Documents container. A small useful guide makes it discoverable immediately.
            let guide = self.documents.appendingPathComponent("Cassette Guide.txt")
            if !fm.fileExists(atPath: guide.path) {
                try """
                Add music to Cassette

                On your iPod: Files → Browse → On My iPod → Cassette.
                Other apps can use the Files picker to copy audio into this folder.
                On your Mac: connect and unlock the iPod, trust this computer, open Finder,
                select the iPod → Files → Cassette, and drag your audio files into the app.
                Cassette checks saved folder timestamps at launch and scans only changed music folders. Use Settings → Rescan Library for immediate discovery.
                Keep M3U playlists and LRC lyrics alongside the audio using their relative paths.
                Your playlists and favorites are stored privately; deleting this guide does not affect them.
                """.write(to: guide, atomically: true, encoding: .utf8)
            }
            try fm.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            database = try LibraryDatabase(inMemory: inMemory, storeURL: databaseURL)
            checkpoints = Dictionary(uniqueKeysWithValues: try database!.all("scanCheckpoint", as: ScanCheckpoint.self).map { ($0.sourceID, $0) })
            tracks = try database!.all("track", as: Track.self)
            trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            sources = try database!.all("source", as: MusicSource.self)
            appleMusicEnabled = (try? database?.all("appleMusicPreference", as: Bool.self).first) ?? false
            playlists = try database!.all("playlist", as: MusicPlaylist.self)
            playbackHistory = try database!.all("history", as: PlaybackHistoryEntry.self).sorted { $0.playedAt > $1.playedAt }
            for index in sources.indices where sources[index].isOwned && sources[index].name != "Cassette" {
                sources[index].name = "Cassette"; try save(sources[index])
            }
            if !sources.contains(where: { $0.isOwned }) {
                let source = MusicSource(id: UUID(), name: "Cassette", isOwned: true)
                sources.insert(source, at: 0); try save(source)
            }
        } catch { errorMessage = "Couldn't open your library: \(error.localizedDescription)" }
    }

    func permitsLocation(_ location: TrackLocation, roots: [UUID: MusicSource]? = nil) -> Bool {
        if location.sourceID == Self.appleMusicSourceID {
            return appleMusicEnabled
        }
        let source = roots?[location.sourceID] ?? sources.first(where: { $0.id == location.sourceID })
        return source?.permits(location.relativePath) ?? false
    }

    var visibleTracks: [Track] {
        if let cached = visibleCache { return cached }
        let roots = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let permitted = tracks.filter { track in track.locations.contains { permitsLocation($0, roots: roots) } }
        let availableKeys = Set(permitted.filter(\.available).map { "\($0.title.lowercased())|\($0.artist.lowercased())|\($0.album.lowercased())|\($0.fingerprint)" })
        let result = permitted.filter { track in
            track.available || !availableKeys.contains("\(track.title.lowercased())|\(track.artist.lowercased())|\(track.album.lowercased())|\(track.fingerprint)")
        }
        visibleCache = result; return result
    }
    var sortedTracks: [Track] {
        if let cached = sortedCache { return cached }
        let result = visibleTracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        sortedCache = result; return result
    }
    var historySongs: [PlayedSong] {
        if let cached = historyCache { return cached }
        let visible = Dictionary(uniqueKeysWithValues: visibleTracks.map { ($0.id, $0) })
        var seen = Set<String>()
        let result = playbackHistory.compactMap { entry -> PlayedSong? in
            guard seen.insert(entry.trackID).inserted else { return nil }
            return visible[entry.trackID].map { PlayedSong(entry: entry, track: $0) }
        }
        historyCache = result
        return result
    }
    var recentlyPlayed: [PlayedSong] { Array(historySongs.prefix(10)) }

    func recordPlayback(_ track: Track) {
        guard trackLookup[track.id] != nil, let database = database else { return }
        let entry = PlaybackHistoryEntry(trackID: track.id)
        do {
            try database.save(entry, key: "history:\(entry.id)", kind: "history")
            try database.commit()
            playbackHistory.insert(entry, at: 0)
        } catch { errorMessage = "Couldn't save listening history: \(error.localizedDescription)" }
    }

    func tracks(in source: MusicSource, path: String = "") -> [Track] {
        guard source.enabled else { return [] }
        return sortedTracks.filter { track in
            track.locations.contains { location in
                location.sourceID == source.id && source.permits(location.relativePath) && location.relativePath.hasPrefix(path)
            }
        }
    }

    func track(_ id: String) -> Track? { trackLookup[id] }
    func sourceURL(_ source: MusicSource) throws -> URL {
        if source.isOwned { return documents }
        if let grant = firstScanGrants[source.id] { return grant.url }
        guard let bookmark = source.bookmark else {
            if let cached = resolvedRoots[source.id] { return cached }
            throw CocoaError(.fileReadNoPermission)
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        // If iOS marks the security-scoped bookmark stale while access is active, refresh the saved bookmark data.
        if stale, let refreshed = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var updated = source; updated.bookmark = refreshed
            update(updated); try? save(updated)
        }
        resolvedRoots[source.id] = url
        return url
    }
    func addFolder(_ url: URL, reconnecting: UUID? = nil) {
        let grant = FolderAccess(url)
        do {
            try LocalFilePolicy.check(url)
            var coordinationError: NSError?, isDir = false
            var coordinatedFolder = url
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
                coordinatedFolder = coordinated
                isDir = (try? coordinated.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if let error = coordinationError { throw error }
            guard isDir else { throw CocoaError(.fileReadInvalidFileName) }
            if let id = reconnecting, sources.first(where: { $0.id == id })?.isOwned != false {
                throw CocoaError(.fileReadNoPermission)
            }
            let canonical = coordinatedFolder.resolvingSymlinksInPath().standardizedFileURL
            let ownedRoot = documents.resolvingSymlinksInPath().standardizedFileURL
            // Selecting Cassette's own folder or a subfolder inside it (such as On My iPod → Cassette → Music)
            // does not need a separate external source that could duplicate tracks or request reconnection.
            if reconnecting == nil, (canonical == ownedRoot || canonical.path.hasPrefix(ownedRoot.path + "/")),
               let owned = sources.first(where: { $0.isOwned }) {
                rescan(only: owned.id)
                return
            }
            let queued = folderChanges.reversed().compactMap { change -> MusicSource? in
                if case .add(let source, let grant) = change, grant.url.resolvingSymlinksInPath().standardizedFileURL == canonical { return source }
                return nil
            }.first
            let duplicate = queued ?? sources.first { existing in
                if let existingPath = try? sourceURL(existing).resolvingSymlinksInPath().standardizedFileURL {
                    return existingPath == canonical
                }
                // If an existing external folder with the same name is waiting for reconnect because its old bookmark expired,
                // reuse that source identity instead of creating a second folder and duplicating every song.
                return !existing.isOwned && existing.needsReconnect && existing.name == url.lastPathComponent
            }
            let duplicateSamePathIDs = sources.filter { existing in
                guard !existing.isOwned else { return false }
                if let existingPath = try? sourceURL(existing).resolvingSymlinksInPath().standardizedFileURL {
                    return existingPath == canonical
                }
                return existing.needsReconnect && existing.name == url.lastPathComponent
            }.map(\.id)
            if let duplicate = duplicate, duplicate.isOwned { rescan(only: duplicate.id); return }
            if let duplicate = duplicate, let id = reconnecting, duplicate.id != id {
                errorMessage = "This folder is already in your library."; return
            }
            let targetID = reconnecting ?? duplicate?.id ?? UUID()
            for extraID in duplicateSamePathIDs where extraID != targetID {
                queueFolderChange(.remove(extraID))
            }
            let data = try (try? coordinatedFolder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            var source = MusicSource(id: targetID, name: url.lastPathComponent, bookmark: data, isOwned: false)
            if let old = sources.first(where: { $0.id == source.id }) { source.enabled = old.enabled; source.excludedPaths = old.excludedPaths }
            queueFolderChange(.add(source, grant))
        } catch { errorMessage = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription) Choose the folder again in Files. For cloud storage, download the audio first." }
    }
    private func queueFolderChange(_ change: FolderChange) {
        folderChanges.append(change)
        if scanning { scanStatus = "Updating music folders…"; scanTask?.cancel() }
        else if !clearingArtwork { applyFolderChanges() }
    }
    private func finishScan() {
        scanning = false; scanTask = nil; automaticSources.removeAll()
        for id in firstScanGrants.keys { resolvedRoots[id] = nil }
        firstScanGrants.removeAll()
        applyFolderChanges()
        resumeAutomaticScan()
    }
    private func applyFolderChanges() {
        guard !busy, !folderChanges.isEmpty else { return }
        let changes = folderChanges; folderChanges.removeAll()
        var scanIDs = Set<UUID>()
        for change in changes {
            do {
                switch change {
                case .add(let source, let grant):
                    try save(source)
                    if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source }
                    else { sources.append(source) }
                    resolvedRoots[source.id] = grant.url
                    firstScanGrants[source.id] = grant
                    if source.enabled { scanIDs.insert(source.id) }
                case .remove(let id):
                    guard sources.contains(where: { $0.id == id && !$0.isOwned }) else { continue }
                    var updated = tracks
                    for index in updated.indices {
                        updated[index].locations.removeAll { $0.sourceID == id }
                        if updated[index] != tracks[index] { try database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track") }
                    }
                    checkpoints[id] = nil
                    try database?.remove(key: "checkpoint:\(id)")
                    try database?.remove(key: "source:\(id)"); try database?.commit()
                    sources.removeAll { $0.id == id }
                    resolvedRoots[id] = nil; firstScanGrants[id] = nil
                    if updated != tracks { tracks = updated }
                }
            } catch { database?.container.viewContext.rollback(); errorMessage = "Couldn't update music folders: \(error.localizedDescription)" }
        }
        if !scanIDs.isEmpty { rescan(sourceIDs: scanIDs) }
        else {
            for id in firstScanGrants.keys { resolvedRoots[id] = nil }
            firstScanGrants.removeAll()
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !busy else { errorMessage = "Wait for the current scan to finish before importing."; return }
        scanning = true; scannedCount = 0; scanStatus = "Importing files"
        scanTask = Task {
            let destination = documents
            let worker = Task.detached(priority: .userInitiated) {
                var errors: [String] = []
                for url in urls {
                    if Task.isCancelled { break }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        try LocalFilePolicy.check(url)
                        guard LibraryScanner.extensions.union(["m3u", "m3u8"]).contains(url.pathExtension.lowercased()) else { continue }
                        var target = destination.appendingPathComponent(url.lastPathComponent)
                        if target.standardizedFileURL == url.standardizedFileURL { continue }
                        if FileManager.default.fileExists(atPath: target.path) {
                            target = destination.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6) + "." + url.pathExtension)
                        }
                        var coordinationError: NSError?, copyError: Error?
                        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
                            do { try FileManager.default.copyItem(at: source, to: target) } catch { copyError = error }
                        }
                        if let error = coordinationError ?? (copyError as NSError?) { throw error }
                        try prepareOwnedAudioForBackground(target)
                        // Explicit file import also preserves an adjacent local lyric file when accessible.
                        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
                        if FileManager.default.fileExists(atPath: lrc.path), (try? LocalFilePolicy.check(lrc)) != nil {
                            try? FileManager.default.copyItem(at: lrc, to: target.deletingPathExtension().appendingPathExtension("lrc"))
                        }
                    } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                return errors
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            let cancelled = Task.isCancelled
            if !result.isEmpty { errorMessage = result.prefix(5).joined(separator: "\n") }
            if cancelled { scanStatus = "Import cancelled" }
            finishScan()
            if !cancelled, let owned = sources.first(where: { $0.isOwned }) { rescan(only: owned.id) }
        }
    }

    /// One cheap startup check of app-owned directories; provider roots require explicit actions.
    func discoverChangesOnLaunch() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        checkingFolders = true
        discoveryTask = Task(priority: .utility) {
            defer { checkingFolders = false; discoveryTask = nil }
            for source in sources where source.isOwned && source.enabled {
                do {
                    try Task.checkCancellation()
                    let changed: Bool
                    if let checkpoint = checkpoints[source.id], checkpoint.excludedPaths == source.excludedPaths {
                        changed = try await scanner.directoriesChanged(root: documents, checkpoint: checkpoint)
                    } else { changed = true }
                    try Task.checkCancellation()
                    if changed { pendingAutomaticSources.insert(source.id) }
                } catch is CancellationError { return }
                catch { scanStatus = "Folder check unavailable. Use Rescan Library to retry." }
            }
            if appleMusicEnabled { pendingAutomaticSources.insert(Self.appleMusicSourceID) }
            resumeAutomaticScan()
        }
    }
    func setPlaybackActive(_ active: Bool) {
        playbackActive = active
        if active && !automaticSources.isEmpty {
            pendingAutomaticSources.formUnion(automaticSources); scanTask?.cancel()
        } else if !active { resumeAutomaticScan() }
    }
    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if !active {
            pendingAutomaticSources.formUnion(automaticSources); scanTask?.cancel()
        } else { resumeAutomaticScan() }
    }
    private func resumeAutomaticScan() {
        guard !pendingAutomaticSources.isEmpty else { return }
        guard sceneActive, !playbackActive, !busy else {
            if !busy { scanStatus = "Music changes found. Automatic scan waits until playback stops." }
            return
        }
        let ids = pendingAutomaticSources
        pendingAutomaticSources.removeAll()
        rescan(sourceIDs: ids, automatic: true)
    }

    func rescanIfNeeded(minimumInterval: TimeInterval = 120) {
        guard !busy, Date().timeIntervalSince(lastScan) >= minimumInterval else { return }
        rescan()
    }
    var browse: BrowseIndex {
        if let cached = browseCache { return cached }
        let value = BrowseIndex(tracks: sortedTracks)
        browseCache = value; return value
    }
    func rescan(only id: UUID? = nil) {
        rescan(sourceIDs: id.map { [$0] })
    }
    private func rescan(sourceIDs: Set<UUID>?, automatic: Bool = false) {
        guard !busy, database != nil else { return }
        let selected = sources.filter { $0.enabled && (sourceIDs == nil || sourceIDs!.contains($0.id)) }
        let shouldScanAppleMusic = appleMusicEnabled && (sourceIDs == nil || sourceIDs?.contains(Self.appleMusicSourceID) == true)
        guard !selected.isEmpty || shouldScanAppleMusic else { return }
        var activeIDs = Set(selected.map(\.id))
        if shouldScanAppleMusic { activeIDs.insert(Self.appleMusicSourceID) }
        if !automatic { discoveryTask?.cancel(); pendingAutomaticSources.subtract(activeIDs) }
        automaticSources = automatic ? activeIDs : []
        scanRunCount += 1
        scanning = true; scannedCount = 0; scanStatus = "Preparing scan…"
        if sourceIDs == nil { lastScan = Date() }
        scanTask = Task(priority: .utility) {
            defer { finishScan() }
            for var source in selected {
                if Task.isCancelled { scanStatus = "Scan cancelled"; break }
                scanStatus = "Scanning \(source.name)"
                do {
                    let root = try sourceURL(source)
                    let holdingFirstGrant = firstScanGrants[source.id] != nil
                    let access = holdingFirstGrant ? false : root.startAccessingSecurityScopedResource()
                    defer { if access { root.stopAccessingSecurityScopedResource() } }
                    let snapshot = trackLookup
                    let completedCount = scannedCount
                    let result = try await scanner.scan(root: root, sourceID: source.id, existing: snapshot, cache: artworkDirectory, excluded: source.excludedPaths, checked: { count in
                        await self.updateScanCount(completedCount + count)
                    }, progress: { batch, count in
                        await self.receive(batch, count: completedCount + count)
                    })
                    try Task.checkCancellation()
                    var updated = tracks
                    var changed = false
                    for index in updated.indices {
                        guard result.complete, !result.seen.contains(updated[index].id), updated[index].locations.contains(where: { $0.sourceID == source.id && $0.available }) else { continue }
                        for location in updated[index].locations.indices where updated[index].locations[location].sourceID == source.id { updated[index].locations[location].available = false }
                        changed = true
                        try database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track")
                    }
                    if changed { tracks = updated }
                    try mergeImportedPlaylists(result.playlists, source: source)
                    if result.complete && result.directoryCheckReliable {
                        let checkpoint = ScanCheckpoint(sourceID: source.id, excludedPaths: source.excludedPaths, directories: result.directories)
                        try database?.save(checkpoint, key: "checkpoint:\(source.id)", kind: "scanCheckpoint")
                        try database?.commit()
                        checkpoints[source.id] = checkpoint
                    }
                    if source.needsReconnect { source.needsReconnect = false; update(source); try save(source) }
                    try database?.commit()
                    scanStatus = "\(scannedCount) files checked\(result.skipped > 0 ? "; \(result.skipped) unavailable" : "")"
                    if !result.issues.isEmpty { errorMessage = result.issues.prefix(5).joined(separator: "\n") }
                } catch is CancellationError { scanStatus = "Scan cancelled"; break }
                catch {
                    source.needsReconnect = !source.isOwned; update(source)
                    var updated = tracks
                    for index in updated.indices {
                        guard updated[index].locations.contains(where: { $0.sourceID == source.id && $0.available }) else { continue }
                        for location in updated[index].locations.indices where updated[index].locations[location].sourceID == source.id { updated[index].locations[location].available = false }
                        try? database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track")
                    }
                    if updated != tracks { tracks = updated }
                    try? save(source); errorMessage = "\(source.name): \(error.localizedDescription)"
                }
            }
            if shouldScanAppleMusic && !Task.isCancelled {
                scanStatus = "Scanning Apple Music Library"
                do {
                    var authStatus = appleMusicProvider.authorizationStatus()
                    if authStatus == .notDetermined {
                        authStatus = await appleMusicProvider.requestAuthorization()
                    }
                    try Task.checkCancellation()
                    if authStatus == .authorized {
                        let items = appleMusicProvider.fetchTracks()
                        let snapshot = trackLookup
                        let completedCount = scannedCount
                        let result = try await scanner.scanAppleMusic(items: items, sourceID: Self.appleMusicSourceID, existing: snapshot, cache: artworkDirectory, checked: { count in
                            await self.updateScanCount(completedCount + count)
                        }, progress: { batch, count in
                            await self.receive(batch, count: completedCount + count)
                        })
                        try Task.checkCancellation()
                        var updated = tracks
                        var changed = false
                        for index in updated.indices {
                            guard !result.seen.contains(updated[index].id),
                                  updated[index].locations.contains(where: { $0.sourceID == Self.appleMusicSourceID && $0.available }) else { continue }
                            for location in updated[index].locations.indices where updated[index].locations[location].sourceID == Self.appleMusicSourceID {
                                updated[index].locations[location].available = false
                            }
                            changed = true
                            try database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track")
                        }
                        if changed { tracks = updated }
                        try database?.commit()
                        scanStatus = "\(scannedCount) files checked\(result.skipped > 0 ? "; \(result.skipped) unavailable" : "")"
                    } else {
                        markAppleMusicLocationsUnavailable()
                        errorMessage = "Apple Music library access is turned off. Enable Media & Apple Music in Settings → Privacy → Media & Apple Music."
                    }
                } catch is CancellationError {
                    scanStatus = "Scan cancelled"
                } catch {
                    errorMessage = "Apple Music Library: \(error.localizedDescription)"
                }
            }
            if artworkNeedsTrim { await trimArtwork(); artworkNeedsTrim = false }
        }
    }
    private func mergeImportedPlaylists(_ manifests: [ScannedPlaylist], source: MusicSource) throws {
        guard !manifests.isEmpty else { return }
        var pathIndex: [String: String] = [:]
        for track in tracks {
            for location in track.locations where location.sourceID == source.id && location.available && source.permits(location.relativePath) {
                pathIndex[location.relativePath] = track.id
            }
        }
        var updated = playlists
        var changed = false
        for manifest in manifests {
            let index = updated.firstIndex { $0.importedSourceID == source.id && $0.importedPath == manifest.path }
            var playlist = index.map { updated[$0] } ?? MusicPlaylist(name: manifest.name)
            playlist.name = manifest.name; playlist.importedSourceID = source.id; playlist.importedPath = manifest.path
            playlist.trackIDs = manifest.entries.compactMap { pathIndex[$0] }
            playlist.unresolvedPaths = manifest.entries.filter { pathIndex[$0] == nil }
            if let index = index {
                if updated[index] == playlist { continue }
                updated[index] = playlist
            } else { updated.append(playlist) }
            try database?.save(playlist, key: "playlist:\(playlist.id)", kind: "playlist"); changed = true
        }
        if changed { try database?.commit(); playlists = updated }
    }
    private func updateScanCount(_ count: Int) { if scannedCount != count { scannedCount = count } }

    private func receive(_ batch: [Track], count: Int) {
        do {
            var updated = tracks
            var indices = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.id, $0.offset) })
            var changed = false
            for var track in batch {
                if track.artwork != nil && track.artwork != trackLookup[track.id]?.artwork { artworkNeedsTrim = true }
                if let index = indices[track.id] {
                    track.favorite = updated[index].favorite
                    if track == updated[index] { continue }
                    updated[index] = track
                } else { indices[track.id] = updated.count; updated.append(track) }
                changed = true
                try database?.save(track, key: "track:\(track.id)", kind: "track")
            }
            try database?.commit()
            if changed { tracks = updated }
            updateScanCount(count)
        } catch { errorMessage = "Couldn't save scan results: \(error.localizedDescription)"; scanTask?.cancel() }
    }
    func setEnabled(_ id: UUID, enabled: Bool) {
        guard !busy, var source = sources.first(where: { $0.id == id }) else { return }
        source.enabled = enabled; applyRestriction(source)
        if enabled { rescan(only: id) }
    }
    func setAppleMusicEnabled(_ enabled: Bool) {
        guard !busy, enabled != appleMusicEnabled else { return }
        if !enabled {
            appleMusicEnabled = false
            saveAppleMusicPreference(false)
            markAppleMusicLocationsUnavailable()
            return
        }
        Task {
            var status = appleMusicProvider.authorizationStatus()
            if status == .notDetermined {
                status = await appleMusicProvider.requestAuthorization()
            }
            guard status == .authorized else {
                appleMusicEnabled = false
                saveAppleMusicPreference(false)
                markAppleMusicLocationsUnavailable()
                errorMessage = "Apple Music library access is turned off. Enable Media & Apple Music in Settings → Privacy → Media & Apple Music."
                return
            }
            appleMusicEnabled = true
            saveAppleMusicPreference(true)
            rescan(only: Self.appleMusicSourceID)
        }
    }
    private func saveAppleMusicPreference(_ enabled: Bool) {
        do {
            try database?.save(enabled, key: "appleMusicEnabled", kind: "appleMusicPreference")
            try database?.commit()
        } catch { errorMessage = error.localizedDescription }
    }
    private func markAppleMusicLocationsUnavailable() {
        do {
            var updated = tracks
            for index in updated.indices {
                for loc in updated[index].locations.indices where updated[index].locations[loc].sourceID == Self.appleMusicSourceID {
                    updated[index].locations[loc].available = false
                }
                if updated[index] != tracks[index] {
                    try database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track")
                }
            }
            if updated != tracks { tracks = updated }
            try database?.commit()
        } catch { errorMessage = error.localizedDescription }
    }
    func excludeFolder(_ url: URL, from id: UUID) {
        guard !busy, var source = sources.first(where: { $0.id == id }) else { return }
        do {
            let root = try sourceURL(source).resolvingSymlinksInPath().standardizedFileURL
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if path == root.path { setEnabled(id, enabled: false); return }
            guard path.hasPrefix(root.path + "/") else { errorMessage = "Choose a subfolder inside \(source.name)."; return }
            let relative = String(path.dropFirst(root.path.count + 1))
            if !source.excludedPaths.contains(relative) { source.excludedPaths.append(relative) }
            applyRestriction(source); rescan(only: id)
        } catch { errorMessage = error.localizedDescription }
    }
    func includeFolder(_ id: UUID, path: String) {
        guard !busy, var source = sources.first(where: { $0.id == id }) else { return }
        source.excludedPaths.removeAll { $0 == path }; applyRestriction(source); rescan(only: id)
    }
    private func applyRestriction(_ source: MusicSource) {
        update(source)
        do {
            var updated = tracks
            for index in updated.indices {
                for loc in updated[index].locations.indices where updated[index].locations[loc].sourceID == source.id {
                    if !source.permits(updated[index].locations[loc].relativePath) { updated[index].locations[loc].available = false }
                }
                if updated[index] != tracks[index] { try database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track") }
            }
            if updated != tracks { tracks = updated }
            try save(source)
        } catch { errorMessage = error.localizedDescription }
    }
    func cancelScan() { pendingAutomaticSources.removeAll(); discoveryTask?.cancel(); scanTask?.cancel() }
    func removeSource(_ source: MusicSource) {
        guard !source.isOwned else { errorMessage = "Cassette’s own folder cannot be removed. Turn off scanning instead."; return }
        queueFolderChange(.remove(source.id))
    }
    func favorite(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].favorite.toggle()
        do { try database?.save(tracks[index], key: "track:\(track.id)", kind: "track"); try database?.commit() }
        catch { errorMessage = error.localizedDescription }
    }
    func createPlaylist(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = MusicPlaylist(name: name); playlists.append(playlist); savePlaylist(playlist)
    }
    /// All interactive add paths share this idempotent mutation; existing legacy duplicates are preserved.
    @discardableResult
    func addTrack(_ trackID: String, to playlistID: UUID) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              track(trackID) != nil, !playlists[index].trackIDs.contains(trackID) else { return false }
        var updated = playlists[index]
        updated.trackIDs.append(trackID)
        guard let database = database else { errorMessage = "Your library is unavailable."; return false }
        do {
            try database.save(updated, key: "playlist:\(updated.id)", kind: "playlist"); try database.commit()
            playlists[index] = updated
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    /// Selection rows toggle membership; clearing selection removes any legacy duplicate occurrences too.
    @discardableResult
    func toggleTrack(_ trackID: String, in playlistID: UUID) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return false }
        if !playlists[index].trackIDs.contains(trackID) { return addTrack(trackID, to: playlistID) }
        var updated = playlists[index]
        updated.trackIDs.removeAll { $0 == trackID }
        guard let database = database else { errorMessage = "Your library is unavailable."; return false }
        do {
            try database.save(updated, key: "playlist:\(updated.id)", kind: "playlist"); try database.commit()
            playlists[index] = updated
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func changePlaylist(_ playlist: MusicPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist; savePlaylist(playlist)
    }
    func deletePlaylist(_ playlist: MusicPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        do { try database?.remove(key: "playlist:\(playlist.id)"); try database?.commit() } catch { errorMessage = error.localizedDescription }
    }
    private func savePlaylist(_ playlist: MusicPlaylist) {
        do { try database?.save(playlist, key: "playlist:\(playlist.id)", kind: "playlist"); try database?.commit() } catch { errorMessage = error.localizedDescription }
    }
    private func save(_ source: MusicSource) throws { try database?.save(source, key: "source:\(source.id)", kind: "source"); try database?.commit() }
    private func update(_ source: MusicSource) { if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source } }
    func clearArtwork() async {
        guard !busy else { return }
        clearingArtwork = true
        defer { clearingArtwork = false; applyFolderChanges() }
        let directory = artworkDirectory
        let failure = await Task.detached(priority: .utility) { () -> String? in
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for file in files { try FileManager.default.removeItem(at: file) }
                return nil
            } catch { return error.localizedDescription }
        }.value
        do {
            // Small main-actor database batches leave room for scrolling and preserve edits between batches.
            for start in stride(from: 0, to: tracks.count, by: 50) {
                var updated = tracks
                for index in start..<min(start + 50, updated.count) {
                    updated[index].artwork = nil; updated[index].fingerprint = ""
                    try database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track")
                }
                try database?.commit(); tracks = updated
                await Task.yield()
            }
            if let failure = failure { errorMessage = "Some artwork could not be cleared: \(failure)" }
        } catch { errorMessage = "Couldn't update the artwork cache: \(error.localizedDescription)" }
    }
    @discardableResult
    func trimArtwork(limit: Int = LibraryStore.artworkCacheLimitBytes) async -> Set<String> {
        let directory = artworkDirectory
        let used = Set(tracks.compactMap(\.artwork))
        let accessTimes = ThumbnailLoader.shared.snapshotAccessTimes()
        let evicted = await Task.detached(priority: .utility) { () -> Set<String> in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []
            var candidates: [(url: URL, name: String, size: Int, lastUsed: Date)] = []
            var removed = Set<String>()
            for file in files {
                let name = file.lastPathComponent
                guard used.contains(name) else {
                    try? FileManager.default.removeItem(at: file)
                    removed.insert(name)
                    continue
                }
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize ?? 0
                let diskDate = values?.contentModificationDate ?? .distantPast
                let memoryDate = accessTimes[name] ?? .distantPast
                candidates.append((file, name, size, max(diskDate, memoryDate)))
            }
            // Sort Most Recently Used (MRU) first so Least Recently Used (LRU) files are evicted when over the limit.
            candidates.sort { lhs, rhs in
                if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
                return lhs.name < rhs.name
            }
            var total = 0
            for candidate in candidates {
                if total + candidate.size <= limit {
                    total += candidate.size
                } else {
                    try? FileManager.default.removeItem(at: candidate.url)
                    removed.insert(candidate.name)
                }
            }
            return removed
        }.value
        if !evicted.isEmpty {
            ThumbnailLoader.shared.removeEvicted(evicted, in: directory)
        }
        return evicted
    }

    /// Re-parses a song's embedded artwork on demand when its cached thumbnail was evicted by the LRU cache limit
    /// or cleared by the user, promoting the newly extracted cover to Most Recently Used.
    func restoreArtworkIfNeeded(for track: Track, cacheLimit: Int = LibraryStore.artworkCacheLimitBytes) async {
        guard !clearingArtwork, !artworkRestoreInFlight.contains(track.id) else { return }
        let current = trackLookup[track.id] ?? track
        if let existingName = current.artwork {
            let path = artworkDirectory.appendingPathComponent(existingName).path
            if FileManager.default.fileExists(atPath: path) {
                ThumbnailLoader.shared.touch(existingName)
                return
            }
        } else if !current.fingerprint.isEmpty {
            // Track was already scanned and has no embedded artwork.
            return
        }
        artworkRestoreInFlight.insert(track.id)
        defer { artworkRestoreInFlight.remove(track.id) }

        var restoredName: String?
        for location in current.locations where location.available {
            if location.sourceID == Self.appleMusicSourceID {
                guard appleMusicEnabled else { continue }
                if current.id.hasPrefix("apple-music:"),
                   let pid = UInt64(current.id.dropFirst("apple-music:".count)),
                   let item = appleMusicProvider.fetchTracks().first(where: { $0.persistentID == pid }),
                   let data = item.artworkData?(),
                   let extracted = try? LibraryScanner.writeThumbnail(from: data, to: artworkDirectory) {
                    restoredName = extracted
                    break
                }
                let resolvedURL = location.relativePath.hasPrefix("/")
                    ? URL(fileURLWithPath: location.relativePath)
                    : URL(string: location.relativePath)
                if let url = resolvedURL {
                    restoredName = await scanner.extractArtwork(from: url, cache: artworkDirectory)
                    if restoredName != nil { break }
                }
                continue
            }
            guard let source = sources.first(where: { $0.id == location.sourceID }),
                  source.permits(location.relativePath),
                  let root = try? sourceURL(source) else { continue }
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            guard let file = try? LocalFilePolicy.musicFile(location.relativePath, in: root) else { continue }
            if let extracted = await scanner.extractArtwork(from: file, cache: artworkDirectory) {
                restoredName = extracted
                break
            }
        }

        guard let filename = restoredName else { return }
        ThumbnailLoader.shared.touch(filename)
        if let index = tracks.firstIndex(where: { $0.id == track.id }), tracks[index].artwork != filename {
            var updated = tracks
            updated[index].artwork = filename
            try? database?.save(updated[index], key: "track:\(updated[index].id)", kind: "track")
            try? database?.commit()
            tracks = updated
        }
        artworkRevision &+= 1
        _ = await trimArtwork(limit: cacheLimit)
    }
}
