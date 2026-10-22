import AVFoundation

/// File-based native decoder. No media is copied or fetched from a network.
@MainActor
protocol AudioEngine: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    var onCompletion: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func load(_ url: URL) throws
    func play() throws
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

@MainActor
final class NativeAudioEngine: NSObject, AudioEngine, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onCompletion: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var duration: TimeInterval { player?.duration ?? 0 }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    func load(_ url: URL) throws {
        stop()
        let isAppleMusicAsset = url.scheme?.lowercased() == "ipod-library"
        guard url.isFileURL || isAppleMusicAsset else { throw PlaybackError.localFilesOnly }
        var candidate: AVAudioPlayer?
        var coordinationError: NSError?
        var decoderError: Error?
        if isAppleMusicAsset {
            do { candidate = try AVAudioPlayer(contentsOf: url) }
            catch { decoderError = error }
        } else {
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { file in
                do { candidate = try AVAudioPlayer(contentsOf: file) }
                catch { decoderError = error }
            }
        }
        if let error = coordinationError ?? (decoderError as NSError?) { throw error }
        guard let candidate = candidate else { throw PlaybackError.decoderFailed }
        guard candidate.prepareToPlay() else { throw PlaybackError.decoderFailed }
        candidate.delegate = self
        player = candidate
    }

    func play() throws {
        guard let player = player, player.play() else { throw PlaybackError.decoderFailed }
    }

    func pause() { player?.pause() }
    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        player?.currentTime = min(max(0, time), duration)
    }
    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self, self.player === player else { return }
            if flag { self.onCompletion?() }
            else { self.onFailure?(PlaybackError.decoderFailed) }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self = self, self.player === player else { return }
            self.onFailure?(error ?? PlaybackError.decoderFailed)
        }
    }
}

enum PlaybackError: LocalizedError {
    case localFilesOnly, decoderFailed
    var errorDescription: String? {
        switch self {
        case .localFilesOnly: return "Only local audio files can be played."
        case .decoderFailed: return "The native decoder could not play this audio file."
        }
    }
}

/// Preserve error identity while giving file-access failures an actionable explanation.
func playbackErrorMessage(_ error: Error) -> String {
    let value = error as NSError
    if (value.domain == NSOSStatusErrorDomain && value.code == -54) ||
        (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError) {
        return "Cassette couldn't read this audio file. Unlock your iPod and try again. For a selected folder, reconnect it in Settings → Music Folders. If it keeps failing, import a fresh local copy into Cassette. (\(value.domain) \(value.code))"
    }
    return "\(value.localizedDescription) (\(value.domain) \(value.code))"
}

func prepareOwnedAudioForBackground(_ url: URL) throws {
    #if !targetEnvironment(macCatalyst)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    #endif
}
