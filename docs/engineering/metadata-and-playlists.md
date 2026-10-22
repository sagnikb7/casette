# Metadata, playlists and access

## Selected folders

The system picker grants a selected directory; minimal bookmarks persist that grant and security-scope access is balanced around scans/playback. The original picker grant is retained through the first scan, including cancellation of another scan. Folder additions/removals are serialized after scan cancellation (or cache cleanup) finishes, preventing silent refusal and stale scan updates from restoring removed sources. Local/provider folders are no longer refused just because their path contains File Provider Storage. Root directory readability is checked through file coordination, rather than an uncoordinated POSIX precheck. Directory checks avoid cloud-file-only resource properties. Bookmark resolution checks access after starting security scope. Download provider music in Files first. Cloud-only iCloud audio, symbolic links and playback paths escaping the source root remain rejected. This does not provide global access to On My iPod.

[Apple directory-access documentation](https://developer.apple.com/documentation/uikit/providing-access-to-directories) describes the picker/bookmark model. Native tests cover local roots with provider-style paths and stored bookmark resolution; actual iOS provider permission/revocation still needs device QA.

## Imported playlists

The scan pass discovers M3U/M3U8 files up to 2 MB. UTF-8/BOM and legacy Windows-1252 are supported. Comments are skipped; Windows separators normalized; relative paths are based on the manifest's directory. Local absolute/file URLs are accepted only inside the same selected root. Remote URLs/hosts and escapes are skipped without being opened.

Order and duplicates are preserved. A missing/excluded entry stays in unresolved-path feedback. The source ID and relative manifest path identify an imported playlist so rescans refresh the same record. Playlist/source removal never deletes music. Imported edits may be replaced on rescan; the UI says the file is the source. Manifests that disappear leave their last indexed playlist intact. Add the containing music folder or copy manifest and music together; importing a manifest alone cannot grant its referenced files.

Manifest and audio/LRC fingerprints skip unchanged parsing. Missing paths are canonicalized via the nearest existing parent, handling macOS /var aliases without dropping unresolved entries. Existing playlist records decode with optional import fields; database identity/schema stay unchanged.

## Artist photos and metadata

The user requested artist-image and metadata enrichment. Primary 600×600 artist artwork and catalog genre/albums are fetched from the public iTunes Search API (`itunes.apple.com`, downloading `600x600bb.jpg` from `*.mzstatic.com`). Structured artist metadata (origin/country, active years, artist type, disambiguation, and tags) is lazily fetched from the public [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API) only when opening an artist's detail page (`includeDetails: true`). Wikimedia's public [PageImages API](https://www.mediawiki.org/wiki/API:Pageimages) (`pilicense=free`) and [ImageInfo](https://www.mediawiki.org/wiki/API:Imageinfo) remain as a fallback if iTunes returns no match. No key, account or SDK is used.

Artist rows initiate image requests only when needed after a 100ms scroll debounce. The setting is enabled by default and stops new lookups when disabled; existing cached photos and metadata remain available offline. Requests send artist names plus normal HTTP/IP information, not audio, filenames or local paths. About and Settings disclose this exception to local music playback.

The ephemeral client identifies Cassette with version/project URL, enforces per-service rate limits (`itunes.apple.com` at 250ms spacing, `musicbrainz.org` at 1.0s spacing, and `en.wikipedia.org`/`upload.wikimedia.org` at 0.8s spacing), applies timeouts and size limits, and restricts requests/redirects to `itunes.apple.com`, `*.mzstatic.com`, `musicbrainz.org`, `en.wikipedia.org`, `upload.wikimedia.org` and `thumb.wikimedia.org`. Thumbnails are resized to at most 600 pixels so the same cached image remains sharp in artist-page headers. Legacy 160-pixel cache entries are refreshed once on demand; if that refresh fails, the existing image remains available and observes the normal retry delay. A generated cache is periodically trimmed to 10 MB; cached images are reused, no-match results retry after a day, and network failures back off five minutes. Canceled lookups do not write a negative cache entry. There is no periodic background metadata job.

On Artist detail pages, a collapsible Apple Music-style About card displays a two-line truncated description and metadata pills (genre, origin, active years) that expand smoothly when tapped. Photo records include creator, license and original file page. Long-press an artist row → Photo Credit shows full attribution/links and resizing notice. Source images retain their individual licenses. See [Wikimedia API etiquette](https://www.mediawiki.org/wiki/API:Etiquette).

## Project link

`scripts/update_project_metadata.py` reads origin, converts GitHub SSH/HTTPS to a credential-free browser URL, and bundles Resources/Project.json. Settings About and the About page open that link in the default browser. Project generation/build refreshes this metadata; tests validate remote conversion. No Git credentials are bundled.

## Audio format and bitrate

Optional `Track.audioFormat` and `Track.bitrate` fields preserve backward compatibility with old stored JSON. Metadata scanning reads AVAsset audio-track format descriptions/estimated bitrate; AudioToolbox encoded-file headers provide a fallback. PCM bitrate uses encoded sample rate and frame size. The UI never estimates bitrate from total file size including artwork; unavailable rates are labeled explicitly. Existing records are enriched once on their next scan, then unchanged fingerprints reuse the metadata. Playback-clock updates perform no file I/O.

## Files and Finder sharing

The iOS Documents path, app identifier and private database paths remain stable. File sharing/open-in-place keys expose Documents in Files and Finder. A small non-audio transfer guide makes the folder discoverable at first launch and is ignored by audio scans. See [transfer steps](../build/ipod-installation.md). Actual provider permission grants and Finder transfers remain physical-device checks.

## Media discovery schedule

Saved records appear immediately. Startup checks persisted directory stamps for the owned source, without enumerating unchanged songs. Changed/missing checkpoints schedule one owned-source scan when foregrounded and not playing. Playback/backgrounding cancels and defers automatic work; explicit user Cancel clears pending work. External/provider roots are not probed automatically. Import scans the owned source, and source mutations scan the affected enabled roots.

Files/Finder changes during a session, provider-folder changes and in-place tag/lyric edits require manual Rescan Library or a per-source scan. Directory timestamps detect structural changes, not every content edit. There is no cloud audio sync, live watcher or interval-based scan. Completed checkpoints persist across launches; interruption does not advance them. Unchanged records bypass merge batches; incomplete enumeration does not mark unseen tracks unavailable.
