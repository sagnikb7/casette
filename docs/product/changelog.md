# Cassette changelog

Every user-facing feature or fix is recorded here when its release build succeeds. Pending changes and their intended semantic bump are maintained in `release/version.json`; see [versioning](../build/versioning.md).

## Unreleased

The build workflow moves pending feature/fix notes into a dated release section after successful packaging.

## 1.7.4 — 22 October 2026

Build: 34.

### Added

- Play or shuffle an entire folder (including all nested subfolders) directly from Library → Folders and inside any folder or subfolder view.

## 1.7.3 — 22 October 2026

Build: 33.

### Fixed

- Extend the Now Playing ArtworkSurface and sheet clip shape edge-to-edge across the status bar and home-indicator safe areas so the top status bar is never left uncolored.

## 1.7.2 — 22 October 2026

Build: 32.

### Fixed

- Embed App Group entitlements and DER entitlements directly in the packaged iOS app and widget extension binaries so sideloading and re-signing tools provision shared widget storage.
- Resolve re-signed App Group identifiers dynamically from embedded provisioning metadata and runtime bundle identifiers, with shared UserDefaults fallback for widget snapshots and artwork.
- Avoid duplicate opaque foreground backgrounds on iOS 17+ and preserve full-color cover and brand rendering in iOS 18+ accented Home Screen widget modes.
- Keep forced widget timeline reloads across startup library updates, restore evicted artwork before publishing, and refresh widgets on scene activation and backgrounding.

## 1.7.1 — 22 October 2026

Build: 29.

### Changed

- Increase the disk artwork cache limit from 50 MB to 200 MB.
- Slightly reduce Dark Mode saturation on the Now Playing ambient artwork background for softer color balance.
- Replace alphabetical artwork cache trimming with a content-addressed SHA-256 deduplicated Least Recently Used (LRU) cache that re-parses evicted song artwork on demand when viewed or played.

## 1.7.0 — 22 October 2026

Build: 28.

### Added

- Add an Apple Music Library toggle in Settings → Music Library and Settings → Music Folders to read and play local DRM-free songs from the iOS Media Library alongside folder-based tracks.
- Index Apple Music song metadata, artwork, lyrics, and audio format details while skipping cloud-only or DRM-protected items and preserving favorites and playlists when toggled off.

## 1.6.4 — 22 October 2026

Build: 27.

### Changed

- Add top and bottom linear gradient fade masks to the synced and plain lyrics scroll containers so scrolling lyrics blend smoothly into the border instead of clipping abruptly.
- Reduce Now Playing album art scale so the playing state uses the previous paused size (0.92x) and the paused state shrinks to 80% of that size (0.736x).

### Fixed

- Clip and fade-mask MarqueeText to its container bounds rather than the inner fixedSize scroller width so scrolling titles never bleed across adjacent controls.
- Keep a fixed 44-point trailing frame and 8-point spacing for the Now Playing 3-dot options menu so long song titles stop and fade cleanly before the menu button.

## 1.6.3 — 22 October 2026

Build: 26.

### Fixed

- Improved Now Playing text, control, and scrubber contrast in Light Mode against vibrant album-artwork backgrounds, including fixing the hardcoded white ellipsis button.
- Enlarged Now Playing album artwork in both playing and paused states by tightening vertical spacing across the header, progress bar, and transport controls on compact 4-inch screens.

## 1.6.2 — 22 October 2026

Build: 25.

### Fixed

- Fixed Now Playing interactive slide-down transition getting stuck halfway when re-opened from the MiniPlayer by separating sheet-chrome slide transitions from matchedGeometryEffect("playerArtwork") and resetting dismiss drag state within the spring transaction.
- Songs with multiple semicolon-separated artists now index each artist separately in the Artists list, display clean comma-separated names, and let you choose which artist to open from Go to Artist or by tapping an artist name in Now Playing.
- Fixed the Now Playing album art drop shadow getting clipped at the top edge of the song title row during playback.

## 1.6.1 — 22 October 2026

Build: 24.

### Fixed

- Removed the faint single-pixel border around Now Playing album art and cropped 2px per side to hide embedded cover edge artifacts.
- Now Playing dismiss is an Apple Music-style interactive sheet slide-down: a grabber pill, dimmed backdrop, and rounded top corners move with the whole sheet, and the release spring now continues smoothly into the MiniPlayer morph instead of snapping first.

## 1.6.0 — 14 October 2026

Build: 23.

### Added

- iTunes 600x600 artist artwork lookup with lazy MusicBrainz artist metadata enrichment (origin, active years, artist type, tags) and a collapsible Apple Music-style About card on artist pages.

### Changed

- Directional spring bounce on Now Playing album art when transitioning from paused to playing, critically damped settle on pause, and smooth matched-geometry artwork morphing into the MiniPlayer when minimizing or expanding.
- Vibrant album-art ambient background in Now Playing for both Light and Dark Mode with boosted color saturation and a lighter, depth-graded scrim.
- Isolated PlaybackClock tick observation into dedicated progress and synced-lyrics subviews, pre-decoded library artwork thumbnails, removed per-cell GeometryReaders, and cached history and search/filter computations.

### Fixed

- Preserved security-scoped and coordinated folder URLs when scanning external On My iPod folders so iOS does not drop folder read permissions mid-scan.
- Eliminated duplicate 'Unavailable · reconnect folder' song rows and automatically reconnected matching disconnected folders when re-adding them.

## 1.5.6 — 13 October 2026

Build: 22.

### Changed

- Artist pages now fetch and cache higher-resolution photos, while retaining an existing thumbnail if an upgrade fails.
- Recently Played shows each song only once, represented by its latest play.

## 1.5.5 — 13 October 2026

Build: 21.

### Changed

- Artist song pages show the available artist photo as a full-width header behind the artist name, fading into the current light or dark background.
- Now Playing artwork swipes use smoother rubber-band tracking and spring transitions.
- Now Playing artwork, title clipping, song-options tap target, song-count alignment, and mini-player transport sizing were refined.

### Fixed

- Left-edge swipes reliably go back one level from library and other pushed navigation screens.

## 1.5.4 — 13 October 2026

Build: 20.

### Changed

- Sleep timer moved from the Now Playing header into the song options menu.
- Now Playing song title stays on one line and scrolls with faded edges when too long.
- Larger Now Playing artwork with rounder corners; drag it sideways to skip to the next or previous song.
- Songs lists show the song count beside the title and use a sort icon at the top right.
- Mini player play/pause and next buttons now match in size.
- More subtle dividers in every list.

### Fixed

- The last song in a list is no longer hidden behind the mini player.

## 1.5.3 — 13 October 2026

Build: 15.

### Changed

- Replace the frosted logo with the latest designer-provided retro rainbow cassette across app, widgets and current documentation.
- Document exact scan triggers, folder-check limitations and manual refresh behavior.

### Fixed

- Skip unchanged startup audio scans using persistent per-directory checkpoints; defer automatic scans while playing or backgrounded.
- Keep external provider rescans explicit and preserve checkpoints across interrupted scans.

## 1.5.2 — 13 October 2026

Build: 14.

### Changed

- Replace the app icon, widget marks and current documentation branding with the designer-provided frosted rainbow cassette.
- Document local media discovery and widget recovery in README and engineering guides.

## 1.5.1 — 13 October 2026

Build: 13.

### Fixed

- Recover widget snapshots on launch and manual refresh, with a scheduled timeline retry.
- Bound widget artwork decoding and preserve readable fallback content when covers are unavailable.
- Keep shared widget snapshots readable after first unlock and expose shared-storage status in Settings.

## 1.5.0 — 13 October 2026

Build: 12.

### Added

- Queue-aware sleep timer with timed, end-of-song and end-of-queue stopping.

### Changed

- Scan once at launch instead of on repeated foreground transitions; coalesce scan updates and reuse unchanged records.
- Consolidate duplicated Settings links and playback preferences.

### Fixed

- Harden background file access, audio session transitions and incomplete scan handling.
- Downsample embedded artwork to reduce scan memory pressure.

## 1.4.1 — 13 October 2026

Build: 11.

### Changed

- Refresh Cassette project branding with the production logo, polished README badges and screenshots, current release details and clearly separated historical documentation.

## 1.4.0 — 13 October 2026

Build: 10.

### Added

- Recently Played shows the last ten song plays with artwork and opens a persistent full listening history.

### Changed

- Album artwork casts a playback shadow; mini-player and tab bar use matching translucency.
- Larger Now Playing seek handle and touch-and-hold seeking on transport controls.
- Library category and playlist song counts align to the right of each list row.
- Folder Settings show live rescan counts, including small folders and skipped files, accumulated across sources.
- Double-tap Now Playing album art to play or pause.

## 1.3.0 — 12 October 2026

Build: 9.

### Added

- Now Playing displays cached audio codec/format and bitrate when available.
- All song-row menus offer Go to Artist and Go to Album.
- Square and horizontal Cassette home-screen widgets display a shared local last-played snapshot and open the player on iOS 15.
- Explicit build --platform=ipod/mac commands export versioned iPod IPA/ZIP or a local universal Mac .app/ZIP with platform-aware validation and release tracking.

### Changed

- Smaller Now Playing seek thumb retains a 44-point scrub target; options icon is white and redundant player menu actions are removed.
- Playing Next uses denser rows and right-aligned shuffle/repeat controls. Timed lyrics use compact rows and always auto-follow without a Follow button.
- Rebrand SoundBunker to Cassette with an original cassette icon, preserving bundle identity and private storage paths; project link follows renamed origin.

### Fixed

- External folder additions/removals serialize safely against scans and retain picker access through initial scanning; removal is available in source details and swipe actions.
- Files/Finder sharing is verified and a non-audio transfer guide makes the app Documents folder discoverable from first launch.

## 1.2.0 — 12 October 2026

Build: 8.

### Added

- Automatic local M3U/M3U8 playlist discovery, ordered entries and unresolved-file feedback.
- Optional cached artist photos from Wikimedia with attribution and privacy controls.
- GitHub project link derived from the origin remote.
- Song-menu artist/album navigation, artwork swipe navigation and modal edge-back support.
- Smooth compact timed lyrics with auto-follow and manual-scroll pause.

### Changed

- Cached album/artist/genre browsing and throttled foreground scans.
- Faster bounded animations and a lyrics clock that runs faster only when lyrics are visible.

### Fixed

- Removed blanket File Provider Storage rejection for folders selected in Files.
- Playback-request artwork feedback starts before asynchronous audio-session activation.

## 1.1.5 — 12 October 2026

Build: 7.

### Changed

- Apple Music-inspired Now Playing layout with persistent Lyrics, Favorite and Queue controls.
- Song options moved beside track details above the progress bar; Shuffle and Repeat moved into Playing Next.
- Larger non-overlapping tap targets throughout Now Playing and the mini-player.
- Visual press feedback for player/mini-player/song rows and subtle selected-state highlights.
- Album artwork expands on play and contracts on pause using a short cached-image transform; Reduce Motion disables movement.

### Fixed

- Aligned Now Playing header controls to the content edges and centered its title, including the empty-player state.

## 1.1.4 — 12 October 2026

Build: 6.

### Changed

- IPA and ZIP filenames now include the release version, validated against the built app in local and CI workflows.

## 1.1.3 — 12 October 2026

Build: 5.

### Changed

- Restored the simpler grouped Settings layout with direct controls while preserving all settings functionality.

## 1.1.2 — 12 October 2026

Build: 4.

### Fixed

- Playback rechecks enabled folders and exclusions before opening each indexed file.
- Local file access rejects symbolic links and paths escaping the selected music folder.

## 1.1.1 — 12 October 2026

Build: 3.

### Changed

- Compact Settings navigation title preserves more space for controls on the iPod screen.

## 1.1.0 — 12 October 2026

Build: 2.

### Added

- Organized Settings with dedicated playback, appearance, library statistics, storage and About screens.
- Playback-position preference and accessible controls for repeat and shuffle.
- Version/build display and bundled What's New release notes.
- Changelog-backed version preparation before builds, with build numbers committed only after successful packaging.

### Changed

- Compact list spacing for the iPod while retaining readable text and 44-point controls.
- Cached library browsing and track lookups, batched scan publishing, and once-per-song lyric parsing.
- New modern SoundBunker icon, rendered as a static opaque asset with no runtime drawing cost.

### Fixed

- Artwork cache clearing now requires confirmation and disables during scans.

## 1.0.0 — 12 October 2026

Historical baseline: earlier IPAs used display version `1.0` and build `1`.

### Added

- Local Core Data library, folder/file intake, automatic scanning and folder exclusions.
- Songs, albums, artists, genres, folders, search, favorites and editable playlists.
- Native playback, persisted queues, system controls and local lyrics.
- SoundBunker name/icon and IPA + ZIP packaging.

### Changed

- Compact Now Playing with pinned controls and cached rotated/blurred artwork tint.
- Artwork in playlist choosers, checkmark feedback and reversible duplicate-safe selection.

### Fixed

- Canonical folder-path handling and metadata fallback for playable files.
- Mini-player tab-bar offset while the keyboard is visible.
