# Product decisions

## Cassette identity

The user selected **Cassette** on 12 October 2026. On 13 October 2026, the user supplied a designer-created retro rainbow cassette to replace the original production logo everywhere in the app, widgets and current documentation. The original PNG is preserved without redesign. Public documentation, installed display names, widgets and new artifact names use Cassette. The repository’s exact spelling remains `sagnikb7/casette`.

Internal Xcode target/bundle identifiers and existing database/cache locations remain stable so renaming does not reset users’ data. Original user design references, earlier icon assets and pre-rebrand release/test records remain historical evidence; they are not current branding.

## Usable local-first library

The supplied prototype informs navigation, spacing and system styling; its catalog/artwork/statistics are illustrative and are never shipped. The test tone was moved entirely to test fixtures. The app starts with actions to add folders/import actual audio rather than playback diagnostics.

## Automatic discovery and restrictions

Check saved directory timestamps in the app-owned folder once at launch; unchanged folders skip scanning. Changed/missing checkpoints scan only when foregrounded and not playing. Provider roots require explicit refresh. Foreground/unlock does not initiate new checks. Explicit rescans remain available; import/source changes scan affected enabled sources. Skip unchanged metadata by fingerprint; use bounded background work and incremental results. No always-on/background directory watcher is promised.

The On My iPod location is a Files UI grouping, not an unrestricted root. Access to other apps' local folders requires explicit directory selection through Apple's picker. Source switches and excluded subfolder paths allow users to restrict scans. Excluded tracks remain indexed for data preservation but are hidden from library browsing; independent permitted source memberships still work. Reconnection retains restrictions.

Cloud-only iCloud audio is skipped; explicitly selected downloaded provider folders are allowed. The earlier blanket File Provider Storage path refusal was removed at the user’s request. Third-party providers control their own file availability. File import is an explicit copy action, unlike folder registration, which indexes originals in place. Neither source removal nor playlist deletion removes audio files.

## Build preferences

Every create build request returns an unsigned Release IPA plus a ZIP containing it. This preference is saved in repository instructions and implemented by the build script. Signing and physical installation are separate actions requiring a working installer/account setup.

## Artist-image exception to the original offline specification

On 12 October 2026 the user explicitly requested a free trusted artist-image API, and on 14 October 2026 expanded it to fetch 600×600 artist artwork from the iTunes Search API plus lazy-loaded artist metadata (origin, active years, type, tags, and description) from MusicBrainz, with Wikimedia Commons retained as a fallback. Music, album art and lyrics remain local; artist photos and metadata are enabled by default, fetched on demand with per-service rate limiting, and cached offline with attribution. Artist names and normal network information are sent; audio and local paths are not uploaded. The switch stops new lookups but allows cached photos and descriptions. Ambiguous/missing/network-failed results use placeholders. This request supersedes the original spec’s prohibition on network enrichment for artist photos and artist descriptions only.

## Cassette rebrand and widgets

On 12 October 2026 the user renamed the app Cassette and selected the compact artwork/track widget concept (second displayed design). The initial ivory/coral icon was superseded by the user-supplied retro rainbow design on 13 October 2026. Original pre-rebrand icon/reference history is preserved in design assets. The repository was renamed by the user to `sagnikb7/casette`; its spelling is preserved exactly in origin and the project link.

Only display names, artwork and future artifact prefixes change. Existing `com.local.offlinemusicplayer`, database/schema and private cache paths stay stable. Source IDs are retained while the owned source display name becomes Cassette. A new transfer guide does not delete user documents or the older guide.

Small/medium WidgetKit widgets show last-played local music. iOS 15 taps open the app without autoplay; no nonfunctional transport controls are drawn. Widget metadata/artwork uses an App Group separate from the private library database. Matching app/extension group provisioning is required; a missing group uses an empty state rather than breaking playback. No full-app data migration or new account/API is introduced.
