# Cassette branding and widgets

Updated 13 October 2026 for widget recovery and the designer-provided retro rainbow mark. Current package validation is recorded in [build receipt](../testing/verification/final-build.md).

## Selected design

The user chose the second displayed concept: [compact artwork/track layout](assets/widget-selected-concept.png). This pre-rebrand concept is a historical reference. The implemented widgets use the new Cassette icon instead of the previous mark, real local cover art, and a music-note fallback when artwork is absent. Concept songs/art are not bundled as app media.

- Square: artwork upper left, small Cassette mark upper right, last-played label, title and artist.
- Horizontal: larger artwork left, track/artist right, and an Open player navigation affordance.
- Empty: Cassette/Open library. Tap opens Library instead of an empty player.

Native renders: [square](../testing/verification/cassette-widget-square.png), [horizontal](../testing/verification/cassette-widget-horizontal.png), [empty](../testing/verification/cassette-widget-empty.png). These use isolated mock text and the genuine no-artwork fallback for verification, not shipped demo music. WidgetKit supplies its own rounded mask; the app preview applies the same corner treatment.

## iOS 15 behavior

The extension supports `systemSmall` and `systemMedium`, targeting iOS 15. `widgetURL` opens `cassette://player` or `cassette://library`. It does not autoplay, read arbitrary paths or accept URL parameters. iOS 15 widgets cannot execute in-place playback controls; [Apple’s interactive-widget guidance](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) introduces those buttons for iOS 17+. Existing app/system media controls continue handling playback.

Settings → Playback → Widgets previews both native card layouts and explains installation. After a signed installation, touch and hold the Home Screen → + → Cassette → select size → Add Widget.

## Snapshot and performance

`WidgetSnapshotStore` writes only title, artist and a generated cover filename to the resolved App Group (`group.com.local.offlinemusicplayer` or the re-signed group extracted from `embedded.mobileprovision` / runtime bundle identifier) and mirrors compact snapshot/thumbnail state in shared `UserDefaults`. No audio, bookmarks, favorites, playlists or private database is copied. Covers reuse the app’s already-downsampled local JPEG, at most 2 MB; only the latest and one preceding image are retained. The extension independently downsamples to at most 320 pixels and rejects symlink/oversized artwork. Cover failures preserve text and the music-note fallback. Shared writes use after-first-unlock protection on iOS. JSON reads are limited to 64 KB, unsafe paths/symlinks are rejected, and unchanged snapshot writes are suppressed.

The provider has a single-entry timeline with a requested retry after 30 minutes. Changed metadata triggers `reloadTimelines(ofKind:)`; app launch and manual Refresh Widgets force recovery even for unchanged metadata. System timing remains controlled by WidgetKit. Updates happen when the track changes or indexed metadata changes (debounced), never from progress ticks or Play/Pause. Superseded publication tasks cancel before committing their snapshot. No widget network calls, in-process polling timers, scanning, audio decoding or continuous blur. See [Apple’s timeline guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

## Signing and App Groups

The iPhoneOS app embeds `CassetteWidget.appex`. Its identifier is `com.local.offlinemusicplayer.widget`; the app remains `com.local.offlinemusicplayer`. Both targets use the same App Group entitlement. Catalyst excludes the extension and does not request the iOS group; native desktop tests inject temporary directories.

On a compatible Xcode/device setup:

1. Select the same signing Team for OfflineMusicPlayer and CassetteWidget.
2. Register an App Group supported by that Team. Configure the same group in both target entitlements and `CassetteWidgetConfiguration.appGroup` if the registered name differs.
3. Add App Groups in Signing & Capabilities for both targets; confirm the provisioning profiles include the group and the widget profile matches the app’s identifier prefix.
4. Install the containing app and extension together, launch Cassette, play a local song, then add both widget sizes.
5. Confirm artwork/title update after changing songs, cached display offline, and taps open player/library without starting playback.

An unsigned IPA or a signing tool that strips App Groups does not establish shared access. Re-signing must preserve/provision the extension and matching group; otherwise the widget safely stays empty. This host cannot verify iPod signing/installation. See [App Group setup](https://developer.apple.com/documentation/xcode/configuring-app-groups) and [device installation](../build/ipod-installation.md).

## Branding and assets

The display name is **Cassette**. The user’s exact GitHub repository spelling is [sagnikb7/casette](https://github.com/sagnikb7/casette). Origin and bundled project metadata follow that URL. Bundle identifier, Documents/database/private-cache paths stay stable; owned-source IDs persist while their display name updates. Previously generated pre-rebrand packages/receipts remain historical. New builds use `Cassette-unsigned-<version>.ipa` and `.ipa.zip`.

App icon: `OfflineMusicPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, opaque 1024×1024. Widget mark: a 64px version in both app/widget asset catalogs. Existing artwork/icon references are preserved under `docs/design/assets/`; original HTML references remain untouched.

The current artwork was supplied by the user on 22 October 2026: [original PNG](assets/casette_retro.png). It replaces the earlier retro rainbow mark (`assets/retro-rainbow-cassette-original.png`), which remains preserved. The 1080px original is preserved byte-for-byte, with its full background and framing. A 1024×1024 opaque sRGB render produces the app/README icon (`AppIcon.png` and `assets/cassette-icon.png`); a 64×64 opaque sRGB render produces identical marks for app and extension (`cassette-mark.png`). No generated alternative, recoloring or cropping is used.

## Executed QA

- Native Release Catalyst: **36 tests, zero failures; TEST SUCCEEDED**, including the 32 existing app/folder/player tests.
- Python workflow tests: **18 tests, zero failures**, including platform commands and Mac packaging.
- iPhoneOS app plus embedded extension Release build/static analysis: **ANALYZE SUCCEEDED**; no analyzer findings.
- Read-only validation checks both arm64 binaries, iOS 15 minimum, app/extension versions, widget extension point/identity, matching source entitlements and bundled assets. App icon is 1024px/opaque. No test tone or XCTest resource is present in the device app.
- Regression coverage: persisted snapshots, duplicate-write suppression, missing-group fallback, bounded image retention/oversized covers, invalid/oversized JSON, unsafe artwork paths, known-only deep links, and native square/horizontal/empty renders.

Actual iPod Home Screen rendering, group provisioning, timeline scheduling, device taps, VoiceOver and battery use remain physical-device checks. Desktop card renders and successful extension compilation do not prove widget installation or OS timeline behavior.

## Black-widget recovery — 13 October 2026

Settings → Widgets now exposes shared-storage status and Refresh Widgets. Launch restoration forces publication/reload; missing/corrupt empty snapshots are repaired. Both empty sizes retain visible fallback content. Missing App Groups explain unavailable track data, but do not by themselves explain an entirely black card. Actual extension launch/signing and on-device rendering remain unverified. See [recovery findings and physical acceptance](../testing/verification/widget-recovery-qa.md).
