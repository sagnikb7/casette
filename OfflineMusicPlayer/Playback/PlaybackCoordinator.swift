import AVFoundation
import Combine
import MediaPlayer
import UIKit
import WidgetKit
import Darwin

enum SleepTimerMode: Equatable { case timed, endOfSong, endOfQueue }

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var currentTrack: Track? { didSet { publishWidget() } }
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRequested = false
    private var playbackGeneration = 0
    private var recordedCurrentPlayback = false
    private var lyricsTracking = false
    private var playerVisible = false
    @Published private(set) var duration: TimeInterval = 0
    let clock = PlaybackClock()
    var position: TimeInterval {
        get { clock.position }
        set { clock.position = newValue }
    }
    @Published private(set) var queue: [String] = []
    @Published private(set) var queueIndex = 0
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode = RepeatMode.off
    @Published var errorMessage: String?
    @Published private(set) var widgetStatus: String?
    var title: String? { currentTrack?.title }
    private let engine: AudioEngine
    private let preferences: UserDefaults
    private weak var library: LibraryStore?
    @Published private(set) var sleepTimerMode: SleepTimerMode?
    private var sleepDeadline: TimeInterval?
    private var sleepTask: Task<Void, Never>?
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var scopedRoot: URL?
    private var shouldResume = false
    private var artwork: MPMediaItemArtwork?
    private var widgetTask: Task<Void, Never>?
    private var widgetLibrarySubscription: AnyCancellable?
    private var lastSaved = Date.distantPast

    init(engine: AudioEngine? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.engine = engine ?? NativeAudioEngine()
        self.engine.onCompletion = { [weak self] in self?.advance(natural: true) }
        self.engine.onFailure = { [weak self] error in
            self?.pause(); self?.errorMessage = playbackErrorMessage(error)
        }
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
        catch { errorMessage = error.localizedDescription }
        configureSystemControls()
    }
    deinit {
        widgetTask?.cancel()
        sleepTask?.cancel()
        timer?.invalidate()
        notifications.forEach(NotificationCenter.default.removeObserver)
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
        scopedRoot?.stopAccessingSecurityScopedResource()
    }
    func connect(_ library: LibraryStore) {
        guard self.library == nil else { return }
        self.library = library
        defer { publishWidget(forceReload: true) }
        widgetLibrarySubscription = library.$tracks.dropFirst().debounce(for: .milliseconds(500), scheduler: RunLoop.main).sink { [weak self] _ in self?.publishWidget() }
        if let state = try? library.database?.all("playback", as: PlaybackSnapshot.self).first,
           state.index >= 0 {
            shuffle = state.shuffle; repeatMode = state.repeatMode
            guard !state.queue.isEmpty, state.queue.indices.contains(state.index) else { return }
            queue = state.queue; queueIndex = state.index
            if let track = library.track(queue[queueIndex]) {
                currentTrack = track; duration = track.duration; position = (preferences.object(forKey: "rememberPlaybackPosition") as? Bool ?? true) ? max(0, min(state.position, duration)) : 0
            }
        }
    }
    func play(_ tracks: [Track], startingAt track: Track? = nil, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        cancelSleepTimer()
        queue = tracks.map(\.id); shuffle = shuffled
        if shuffled { queue.shuffle() }
        queueIndex = track.flatMap { queue.firstIndex(of: $0.id) } ?? 0
        loadCurrent(autoplay: true)
    }
    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.insert(track.id, at: min(queueIndex + 1, queue.count)); persist()
    }
    func addToQueue(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.append(track.id); persist()
    }
    func jump(to index: Int) { guard queue.indices.contains(index) else { return }; queueIndex = index; loadCurrent(autoplay: true) }
    func toggleShuffle() {
        shuffle.toggle()
        guard queue.indices.contains(queueIndex) else { return }
        let prefix = Array(queue.prefix(queueIndex + 1))
        var tail = Array(queue.dropFirst(queueIndex + 1))
        if shuffle { tail.shuffle() }
        else { tail.sort { (library?.track($0)?.title ?? "") < (library?.track($1)?.title ?? "") } }
        queue = prefix + tail; persist()
    }
    func setRepeatMode(_ mode: RepeatMode) { repeatMode = mode; persist() }
    func cycleRepeat() { repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off; persist() }
    func next() { advance(natural: false) }
    func previous() {
        if position > 3 { seek(to: 0); return }
        if queueIndex > 0 { queueIndex -= 1; loadCurrent(autoplay: true) } else { seek(to: 0) }
    }
    func previousTrack() {
        if queueIndex > 0 { queueIndex -= 1; loadCurrent(autoplay: true) }
        else if repeatMode == .all && !queue.isEmpty { queueIndex = queue.count - 1; loadCurrent(autoplay: true) }
        else { seek(to: 0) }
    }
    private func advance(natural: Bool) {
        if checkSleepTimer() { return }
        if natural && (sleepTimerMode == .endOfSong || (sleepTimerMode == .endOfQueue && queueIndex + 1 >= queue.count)) {
            cancelSleepTimer(); pause(); position = duration; persist(); updateNowPlaying(); return
        }
        if natural && repeatMode == .one && sleepTimerMode != .endOfQueue { recordedCurrentPlayback = false; seek(to: 0); play(); return }
        if queueIndex + 1 < queue.count { queueIndex += 1; loadCurrent(autoplay: true) }
        else if repeatMode == .all && !queue.isEmpty { queueIndex = 0; loadCurrent(autoplay: true) }
        else { cancelSleepTimer(); pause(); position = duration; persist(); updateNowPlaying() }
    }
    private func loadCurrent(autoplay: Bool) {
        recordedCurrentPlayback = false
        playbackGeneration += 1; playbackRequested = false
        engine.stop(); stopTimer(); releaseAccess(); isPlaying = false; position = 0
        guard let library = library else { return }
        // Skip unavailable entries with a bounded traversal. Never silently replace a track by title.
        var attempts = 0
        while attempts < queue.count, queue.indices.contains(queueIndex) {
            let id = queue[queueIndex]
            if let track = library.track(id), track.available {
                do {
                    try prepare(track)
                    currentTrack = track; duration = engine.duration; loadArtwork(track)
                    errorMessage = nil
                    if autoplay { play() } else { updateNowPlaying() }
                    persist(); return
                } catch { errorMessage = "\(track.title): \(playbackErrorMessage(error))"; releaseAccess() }
            } else { errorMessage = "This song is unavailable. Reconnect or rescan its folder in Settings." }
            attempts += 1
            if queueIndex + 1 < queue.count { queueIndex += 1 } else { break }
        }
        currentTrack = nil; duration = 0; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; persist()
    }
    private func prepare(_ track: Track) throws {
        guard let library = library else { throw PlaybackError.decoderFailed }
        var lastError: Error = CocoaError(.fileReadNoSuchFile)
        for location in track.locations where location.available {
            guard let source = library.sources.first(where: { $0.id == location.sourceID }),
                  source.permits(location.relativePath) else { continue }
            do {
                let root = try library.sourceURL(source)
                let accessed = root.startAccessingSecurityScopedResource()
                if accessed { scopedRoot = root }
                let file = try LocalFilePolicy.musicFile(location.relativePath, in: root)
                if source.isOwned { try prepareOwnedAudioForBackground(file) }
                try engine.load(file)
                return
            } catch { lastError = error; releaseAccess() }
        }
        throw lastError
    }
    func refreshWidgets() { publishWidget(forceReload: true) }
    private func publishWidget(forceReload: Bool = false) {
        let track = currentTrack.flatMap { library?.track($0.id) } ?? currentTrack
        let artworkURL = track?.artwork.flatMap { name in library?.artworkDirectory.appendingPathComponent(name) }
        widgetTask?.cancel()
        widgetTask = Task {
            do {
                let changed = try await WidgetSnapshotStore.shared.publish(title: track?.title ?? "", artist: track?.displayArtist ?? "", artwork: artworkURL, force: forceReload)
                guard !Task.isCancelled else { return }
                if changed || forceReload { WidgetCenter.shared.reloadTimelines(ofKind: CassetteWidgetConfiguration.kind) }
                #if targetEnvironment(macCatalyst)
                widgetStatus = "Home Screen widgets are available on iPod/iPhone. Mac previews do not use shared widget storage."
                #else
                widgetStatus = CassetteWidgetConfiguration.directory == nil
                    ? "Shared widget storage is unavailable. The app and widget must be signed with the same provisioned App Group. Reinstall a correctly signed package to share song details."
                    : "Shared widget data is ready. iOS controls when the Home Screen refreshes."
                #endif
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                widgetStatus = "Couldn't update shared widget data. Unlock your iPod and try Refresh Widgets again. (\((error as NSError).domain) \((error as NSError).code))"
                if forceReload { WidgetCenter.shared.reloadTimelines(ofKind: CassetteWidgetConfiguration.kind) }
            }
        }
    }

    private func releaseAccess() { scopedRoot?.stopAccessingSecurityScopedResource(); scopedRoot = nil }
    func play() {
        if checkSleepTimer() { return }
        guard let current = currentTrack, let track = library?.track(current.id), track.available else {
            if currentTrack != nil { pause(); errorMessage = "This song is unavailable or its folder is excluded." }
            return
        }
        playbackGeneration += 1
        let generation = playbackGeneration
        playbackRequested = true
        Task {
            do {
                guard generation == playbackGeneration, playbackRequested else { return }
                try await PlaybackSession.shared.activate(true)
                guard generation == playbackGeneration, playbackRequested else { return }
                if engine.duration == 0 { let resume = position; try prepare(track); engine.seek(to: resume); duration = engine.duration; loadArtwork(track) }
                if position >= duration { engine.seek(to: 0); recordedCurrentPlayback = false }
                try engine.play(); isPlaying = engine.isPlaying; playbackRequested = isPlaying; position = engine.currentTime
                if isPlaying && !recordedCurrentPlayback {
                    library?.recordPlayback(track)
                    recordedCurrentPlayback = true
                }
                startTimer(); updateNowPlaying()
            } catch {
                guard generation == playbackGeneration else { return }
                isPlaying = false; playbackRequested = false; stopTimer(); errorMessage = playbackErrorMessage(error); updateNowPlaying()
            }
        }
    }
    func pause() {
        playbackGeneration += 1; playbackRequested = false; isPlaying = false
        engine.pause()
        if engine.duration > 0 { position = engine.currentTime }
        stopTimer(); updateNowPlaying()
        let generation = playbackGeneration
        Task {
            guard generation == playbackGeneration, !playbackRequested else { return }
            try? await PlaybackSession.shared.activate(false)
            persist()
        }
    }
    // Continuous monotonic time includes device sleep, unlike an uptime-only clock.
    static var sleepTime: TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    /// Nil means an unknown duration; never guess a finite queue's capacity.
    var remainingQueueDuration: TimeInterval? {
        guard currentTrack != nil, queue.indices.contains(queueIndex), duration.isFinite, duration > 0 else { return nil }
        var remaining = max(0, duration - (engine.duration > 0 ? engine.currentTime : position))
        for id in queue.dropFirst(queueIndex + 1) {
            guard let track = library?.track(id), track.available,
                  track.locations.contains(where: { location in library?.sources.contains(where: { $0.id == location.sourceID && $0.permits(location.relativePath) && location.available }) == true }) else { continue }
            guard track.duration.isFinite, track.duration > 0 else { return nil }
            remaining += track.duration
        }
        return remaining
    }
    func canSetSleepTimer(seconds: TimeInterval) -> Bool {
        guard currentTrack != nil, seconds.isFinite, seconds > 0 else { return false }
        return repeatMode != .off || remainingQueueDuration.map { seconds <= $0 } == true
    }
    @discardableResult func setSleepTimer(seconds: TimeInterval) -> Bool {
        guard canSetSleepTimer(seconds: seconds) else { return false }
        cancelSleepTimer()
        sleepTimerMode = .timed
        sleepDeadline = Self.sleepTime + seconds
        sleepTask = Task { [weak self] in
            // Bounded sleeps avoid overflowing nanoseconds for malformed inputs.
            while !Task.isCancelled {
                let remaining = min(60, max(0.01, (self?.sleepDeadline ?? 0) - Self.sleepTime))
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
                guard let self = self else { return }
                if self.checkSleepTimer() { return }
            }
        }
        return true
    }
    func setSleepBoundary(_ mode: SleepTimerMode) {
        guard currentTrack != nil, mode != .timed else { return }
        cancelSleepTimer(); sleepTimerMode = mode
    }
    func cancelSleepTimer() {
        sleepTask?.cancel(); sleepTask = nil; sleepDeadline = nil; sleepTimerMode = nil
    }
    @discardableResult func checkSleepTimer(now: TimeInterval? = nil) -> Bool {
        guard let deadline = sleepDeadline, (now ?? Self.sleepTime) >= deadline else { return false }
        cancelSleepTimer(); pause(); return true
    }
    var sleepTimerLabel: String {
        switch sleepTimerMode {
        case .timed:
            let seconds = max(0, (sleepDeadline ?? 0) - Self.sleepTime)
            return "Sleep in \(Int(ceil(seconds / 60))) min"
        case .endOfSong: return "Sleep after song"
        case .endOfQueue: return "Sleep after queue"
        case nil: return "Sleep Timer"
        }
    }
    func toggle() { playbackRequested || isPlaying ? pause() : play() }
    func setPlayerVisible(_ visible: Bool) {
        guard visible != playerVisible else { return }
        playerVisible = visible
        if !visible { lyricsTracking = false }
        if engine.duration > 0 { position = engine.currentTime }
        if isPlaying { startTimer() }
    }
    func setLyricsTracking(_ enabled: Bool) {
        guard enabled != lyricsTracking else { return }
        lyricsTracking = enabled
        if enabled && engine.duration > 0 { position = engine.currentTime }
        if isPlaying { startTimer() }
    }
    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        if engine.duration > 0 { engine.seek(to: time); position = engine.currentTime }
        else { position = min(max(0, time), duration) }
        updateNowPlaying(); persist()
    }
    func persist() {
        guard let db = library?.database else { return }
        do {
            try db.save(PlaybackSnapshot(queue: queue, index: queueIndex, position: isPlaying && engine.duration > 0 ? engine.currentTime : position, repeatMode: repeatMode, shuffle: shuffle), key: "playback", kind: "playback")
            try db.commit(); lastSaved = Date()
        } catch { errorMessage = "Couldn't save playback state: \(error.localizedDescription)" }
    }
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: playerVisible ? (lyricsTracking ? 0.2 : 0.5) : 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPlaying else { return }
                self.position = self.engine.currentTime
                if Date().timeIntervalSince(self.lastSaved) > 10 { self.persist() }
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func loadArtwork(_ track: Track) {
        artwork = nil
        if let name = track.artwork, let folder = library?.artworkDirectory,
           let image = UIImage(contentsOfFile: folder.appendingPathComponent(name).path) {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }
    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        if let artwork = artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func configureSystemControls() {
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { $0.play() }; bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.toggle() }; bind(center.nextTrackCommand) { $0.next() }; bind(center.previousTrackCommand) { $0.previous() }
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime; Task { @MainActor [weak self] in self?.seek(to: time) }; return .success
        }))
        let nc = NotificationCenter.default
        notifications.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.pause(); self.engine.stop(); self.releaseAccess()
                do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
                catch { self.errorMessage = playbackErrorMessage(error) }
            }
        })
        notifications.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.shouldResume = self.isPlaying; self.pause() }
                else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    if self.shouldResume && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.play() }
                    self.shouldResume = false
                }
            }
        })
        notifications.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        })
    }
    private func bind(_ command: MPRemoteCommand, action: @escaping (PlaybackCoordinator) -> Void) {
        remoteTargets.append((command, command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in if let self = self { action(self) } }; return .success
        }))
    }
}
