# Architecture

## Ownership and data flow

The SwiftUI App owns one `LibraryStore` and one `PlaybackCoordinator`. Views read observable state and request actions; they never create independent players. The library loads first, then the player restores its stable-ID queue without starting audio. The root checks persisted directory stamps once on first appearance for the owned source. An unchanged checkpoint skips audio enumeration entirely. Missing/changed checkpoints queue a local scan; playback and backgrounding defer/cancel automatic work. Foreground/unlock does not initiate a new check. External providers are scanned only by explicit source/import/rescan actions. Imports scan the owned source; folder changes scan affected sources. Use explicit Rescan Library for Finder/Files changes made during a session; concurrent scans are suppressed.

`LibraryScanner` is an actor with one metadata worker, bounding resource use. It recursively enumerates regular audio candidates, skips hidden files/packages/symlinks, and applies source exclusions before reading metadata. File resource and volume identities deduplicate overlapping roots; separate copies keep separate identities. Size/mtime fingerprints avoid reparsing unchanged files. Results reach the main actor in batches of 25.

`LibraryStore` publishes batch results, saves to Core Data and marks missed files unavailable only after a complete, error-free enumeration. Cancelling retains existing state plus already published additions. A failed source retains indexed identities and user data, marks locations unavailable and exposes reconnection. Removing a source only removes its locations; favorites and playlist references remain, and other source memberships continue to work.

## Persistence

`LibraryDatabase` uses a versioned programmatic Core Data model with keyed `LibraryRecord` entities: source, track, playlist and playback records. JSON payloads retain stable identities, source memberships and version-tolerant source defaults. Unique record keys support updates; automatic lightweight model migration is enabled. Display albums/artists are derived from tracks, including album-artist grouping and disc/track sorting.

Search currently filters the loaded local index. Larger-library indexed SQL search and measured fetch/scroll performance remain work items. Tests isolate their stores and fixtures from production data. Disk persistence is verified separately from in-memory serialization tests.

## File access and offline policy

The app scans its entire Documents directory automatically; it appears as Cassette under On My iPod. No Music subfolder is required. External roots are explicitly selected through UIDocumentPickerViewController, saved as bookmarks and resolved on subsequent opens. Security scope is balanced during scanning and held for the active track until replacement. Readable stale bookmark locations remain usable; unavailable locations request reconnection. Resolved roots are cached and invalidated on reconnection/removal.

Reading/copying provider audio uses NSFileCoordinator. Explicitly selected provider folders are allowed; the previous pathname-based rejection is removed. Cloud-only ubiquitous audio and symbolic links are refused before decoding. Directory placeholders may be enumerated to discover downloaded children. Third-party providers retain control over file availability; download audio in Files first. Arbitrary device-wide access and remote audio streaming are not implemented.

Source enable flags and excluded relative paths persist. Path-boundary matching excludes `Podcasts/…` without excluding `Podcasts Plus/…`. Excluded songs disappear from library browsing while their stored identities/favorites/playlist entries remain. No original media is rewritten or removed.

## Playback

`NativeAudioEngine` wraps AVAudioPlayer, refuses non-file URLs, clamps seeks and ignores callbacks from replaced player instances. The main-actor coordinator resolves a track through its allowed source memberships, skips unavailable queue entries with a bounded traversal, handles natural advance/repeat, remote commands, interruption and headphone removal. It persists on pause, seek, background and at ten-second intervals during playback. No sound starts automatically on relaunch.

Views use a persistent mini-player above the iOS tab bar and a full-screen Now Playing presentation. Native session/Control Center integration is implemented; real-device behavior is not yet certified. Shuffle-off currently sorts the remaining queue by title rather than restoring its pre-shuffle order; this is documented for further refinement.

## Artwork and lyrics

Embedded artwork is reduced to 320×320 JPEGs off the main UI flow and content-addressed by SHA-256 digest so tracks sharing identical album art reuse a single thumbnail file. Disk cache is trimmed to 200 MB using Least Recently Used (LRU) ordering off the main actor when thumbnails are produced, and any song whose cover was previously evicted is re-parsed on demand when viewed or played; thumbnail memory cache is capped at 18 MB. Cache clearing removes generated thumbnails only. A missing thumbnail falls back to a semantic note symbol.

Embedded plain lyrics and matching adjacent UTF-8 LRC are retained in the index. LRC supports offsets and multiple timestamps, highlights by playback time and permits tap-to-seek/manual scroll. No synchronized timestamps are invented for plain text. Binary synchronized tags and codec-specific numeric/tag parsing remain incomplete.

## Compact player and playlist polish

Now Playing reserves a fixed dock outside its scroll regions for seek/transport and the three secondary controls. The artwork shrinks to the remaining height; metadata remains in the dock above progress without pushing the secondary row below the fold. A native 320×548 render was inspected. The root removes the mini-player's 49-point tab-bar padding when keyboard frame notifications report a visible keyboard; keyboard safe-area avoidance supplies its vertical position.

`ArtworkSurfaceCache` is an actor that decodes artwork directly to at most 64 pixels, rotates 180 degrees, applies a cropped/clamped Gaussian blur and stores up to 16 results. A static CIContext and NSCache avoid per-tick rendering and repeated setup. The foreground uses a strong semantic surface overlay for text contrast; Reduce Transparency suppresses the tint. Device CPU/memory/battery profiling remains pending.

`LibraryStore.addTrack(_:to:)` is the shared, idempotent manual-add mutation used by song menus, the playlist song chooser and Now Playing's playlist picker. It reads the latest stored playlist, refuses repeats/missing identities and publishes a checkmark only after a successful database commit. Legacy duplicate entries are preserved; reorder/delete behavior remains unchanged.

Playlist selection uses `LibraryStore.toggleTrack(_:in:)`: an unselected song uses the idempotent add path; a selected song removes all matching IDs, commits, then publishes the updated state. Song menus retain add-only semantics. Both chooser screens reuse the bounded thumbnail cache and expose the current selection/removal action to accessibility.

## Responsiveness and release identity

LibraryStore caches visible/title-sorted tracks and an ID lookup, invalidating when tracks or source policy change. Scan batches save changed records and publish once per batch; unchanged scans avoid track publication. Restriction/removal/failure handling similarly publishes one array update. Lyrics parse on song changes; artwork tint uses the existing tiny cached background. Cache clearing removes generated files on a utility task and resets index metadata in yielding batches without deleting source audio.

Settings reads installed version/build and bundled ReleaseNotes.json. The release manifest and scripts maintain semantic versions, build numbers and the Markdown changelog; branding assets do not change bundle identity, Core Data schema or database paths.

## Feature expansion

M3U discovery shares the scan pass and caches manifest parsing by file fingerprint. Imported origins and unresolved paths are optional JSON fields, preserving old playlist decoding and the existing Core Data schema. Import refresh saves/publishes only changed playlists. LRC sidecar fingerprints refresh changed lyrics.

BrowseIndex caches albums, artists, genres and recent lists. PlaybackClock alone publishes elapsed time, so library consumers do not redraw for progress ticks. PlaybackSession serializes blocking activation away from the UI; a generation token prevents a canceled request from starting audio later. Artwork responds to requested playback, using a bounded 180 ms transform. Only visible timed lyrics use the faster clock and binary-search line lookup.

The metadata layer, network boundaries, attribution, cache/backoff and project link derivation are documented in [metadata and playlists](metadata-and-playlists.md).

## Player and folder refinements (1.2.1 candidate)

The seek control uses a 10-point UIKit thumb with a 44-point scrubbing surface; its cached image is built once. Queue rows retain 44-point targets with no extra spacing; lyric rows use compact intrinsic text sizing (32-point minimum), including wrapping for larger text, and always follow timestamp changes. The redundant player menu actions are removed while all shared song rows support artist/album navigation.

Folder mutations acquire/save picker grants immediately, cancel any current scan, then apply after the task unwinds. Initial grants remain held until the new scan ends; later access resolves saved bookmarks. Removal persists source/location changes while retaining track identity, favorites and playlist references. It never deletes user audio. Source details and swipe actions expose explicit removal.

## Player/library polish — 12 October 2026

The tab bar explicitly uses UIKit system material for both standard and scroll-edge backgrounds, matching the mini-player’s SwiftUI regular material. Now Playing gives the artwork shadow room inside its scroll region; Reduce Motion uses static artwork scale/shadow. The scrubber has a 24-point visible thumb and a 44-point touch surface.

Transport controls arbitrate tap versus hold with a native long-press recognizer. A 0.4-second hold seeks two seconds immediately and every 0.25 seconds thereafter. Existing seek bounds apply without changing songs. Release/cancellation, view teardown and app inactivity stop repetition; VoiceOver has explicit seek actions.

Scanning coalesces checked-audio progress to at most four updates per second plus completion, independently of 25-changed-track persistence batches. Unchanged tracks never enter persistence batches. Embedded artwork is downsampled directly through ImageIO to bound decoded image size. LibraryStore adds each source’s count to the completed-source count so totals do not reset between folders. Shared scan status/cancel UI is present on Settings, Music Folders and folder detail. Library home category counts use the corresponding visible/browse/source collections.

## Listening history

Successful engine starts create individual Codable `PlaybackHistoryEntry` records (`history` kind) in the existing LibraryRecord store, without changing its schema, identity or default database path. Each event has its own UUID, track ID and timestamp. New song loads, explicit replays, automatic queue transitions and repeat-one starts record events; pause/resume within a load does not. Silent restore, cancelled activation and failed starts do not record. History resolves current track metadata/artwork and follows source visibility policy; rescanning or exclusion does not delete stored events.

Library displays the newest ten visible events as horizontal song tiles. The Recently Played category and header chevron open the full Listening History list, newest first, with repeated plays preserved and timestamps. Tiles/rows play their selected song. Older installations begin with an empty history; no history is fabricated from import dates or saved queue state. An optional databaseURL initializer argument supports isolated disk-persistence verification; the default path stays unchanged.

## Sleep timer and locked playback

Now Playing exposes a sleep timer in its header. Timed presets validate against known remaining queue duration unless repeat is enabled. Monotonic deadlines include pauses and are checked before resume/advance; a cancellable task checks expiry while the process runs. End-of-song stops at the next natural ending; end-of-queue overrides repeat-one and repeat-all. Queue replacement cancels timers. Timers are intentionally not restored after process termination.

Owned audio is explicitly set to after-first-unlock protection when imported/opened, and the persistent store uses the same policy. External sources retain their provider protection. Decoder opening is coordinated. Pause deactivation checks its generation before touching the session, and media-services reset discards the stale decoder without unexpected playback. Permission errors preserve diagnostic domain/code and provide recovery steps. Physical locked playback and the reported termination still require device verification.

## Widget recovery

The widget provider requests a 30-minute retry rather than a permanent single entry. Launch restoration/manual refresh forces publication even when metadata is unchanged. Snapshot validity is distinct from an empty library; corrupt or missing empty records can be repaired. Shared JSON/covers explicitly remain accessible after first unlock. Artwork identity hashes bytes, and extension-side ImageIO decoding is capped at 320 pixels. The widget never opens the database or audio. Settings reports shared-storage/write status, while actual extension signing and WidgetKit scheduling remain OS-controlled. See [widget verification](../testing/verification/widget-recovery-qa.md).

## Persistent folder checkpoints

`ScanCheckpoint` records live in the existing keyed database (`scanCheckpoint` kind), preserving bundle/storage identity. The scanner records each included directory’s relative path, resource identity and modification timestamp before traversing it. Only complete scans with reliable directory stamps save a checkpoint; incomplete scans retain the previous one. Reading old databases simply yields no checkpoints and one initial owned-source scan.

The scanner actor compares known directory stamps at launch without enumerating songs. Nested additions/removals change the relevant known parent; adding a new folder changes its known ancestor. Editing existing file contents may leave directory stamps unchanged, so tag/lyric edits require manual rescan. No claim of exact filesystem synchronization or provider timestamp reliability is made. Explicit scans bypass playback deferral. Automatic scans cancel when playback starts, retain pending source IDs while deferred and resume when foreground/idle. User Cancel clears pending automatic work.
