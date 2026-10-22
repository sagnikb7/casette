import SwiftUI

struct AppReleaseNotes: Decodable {
    struct Section: Decodable { var title: String; var items: [String] }
    var version: String
    var sections: [Section]
    static let bundled: AppReleaseNotes? = {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()
}

enum AppIdentity {
    static let projectURL: URL = {
        if let resource = Bundle.main.url(forResource: "Project", withExtension: "json"), let data = try? Data(contentsOf: resource),
           let metadata = try? JSONDecoder().decode([String: String].self, from: data), let value = metadata["githubURL"],
           let url = URL(string: value), url.scheme == "https", url.host == "github.com" { return url }
        return URL(string: "https://github.com/sagnikb7/casette")!
    }()
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var versionLabel: String { "Version \(version) (\(build))" }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("artistPhotosEnabled") private var artistPhotosEnabled = true
    var body: some View {
        List {
            Section {
                NavigationLink("Music Folders") { SourceSettingsView() }
                Button("Import Audio Files") { library.pickerRequest = PickerRequest(folders: false) }.disabled(library.busy)
                Button("Rescan Library") { library.rescan() }.disabled(library.busy)
                NavigationLink("Library Statistics") { LibraryStatisticsView() }
                if library.scanning { ScanProgressView() }
            } header: { Text("Music Library") } footer: {
                Text(library.scanning ? library.scanStatus : "Startup checks saved folder timestamps, not every song. Changed local folders scan when playback stops. Rescan refreshes provider folders and edits to existing tags or lyrics.")
            }
            Section("Playback") {
                NavigationLink("Widgets") { WidgetPreviewView() }
                NavigationLink("Playback Preferences") { PlaybackSettingsView() }
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section {
                Toggle("Online Artist Photos", isOn: $artistPhotosEnabled)
            } header: { Text("Artist Images") } footer: { Text("When Artists is opened, names are sent to Wikipedia/Wikimedia to find free images. Photos are cached for offline use; music and lyrics remain local.") }
            ArtworkCacheSection()
            Section("About") {
                NavigationLink("What's New") { WhatsNewView() }
                NavigationLink("About Cassette") { AboutView() }
            }
        }.listStyle(.insetGrouped).subtleSeparator().miniPlayerClearance().environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("Settings")
    }
}

struct LabeledContentRow: View {
    var label: String; var value: String
    var body: some View { HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) } }
}

struct PlaybackSettingsView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @AppStorage("rememberPlaybackPosition") private var rememberPosition = true
    var body: some View {
        Form {
            Section {
                Toggle("Remember Playback Position", isOn: $rememberPosition)
            } footer: { Text("On the next launch, restore your last song position. Playback always waits for you to press Play.") }
            Section("Current Queue") {
                Toggle("Shuffle", isOn: Binding(get: { playback.shuffle }, set: { if $0 != playback.shuffle { playback.toggleShuffle() } })).disabled(playback.queue.isEmpty)
                Picker("Repeat", selection: Binding(get: { playback.repeatMode }, set: playback.setRepeatMode)) {
                    Text("Off").tag(RepeatMode.off); Text("All Songs").tag(RepeatMode.all); Text("One Song").tag(RepeatMode.one)
                }
            }
        }.subtleSeparator().miniPlayerClearance().navigationTitle("Playback").navigationBarTitleDisplayMode(.inline)
    }
}
struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        List {
            Section {
                ForEach([("system", "Use Device Setting"), ("light", "Light"), ("dark", "Dark")], id: \.0) { value, label in
                    Button { appearance = value } label: {
                        HStack { Text(label).foregroundColor(.primary); Spacer(); if appearance == value { Image(systemName: "checkmark").foregroundColor(.blue) } }.frame(minHeight: 32)
                    }.accessibilityValue(appearance == value ? "Selected" : "")
                }
            } footer: { Text("Use Device Setting follows your iPod's appearance automatically.") }
        }.listStyle(.insetGrouped).subtleSeparator().miniPlayerClearance().navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }
}
struct LibraryStatisticsView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        let visible = library.visibleTracks
        return List {
            Section("Music") {
                LabeledContentRow(label: "Songs", value: "\(visible.count)")
                LabeledContentRow(label: "Available", value: "\(visible.filter(\.available).count)")
                LabeledContentRow(label: "Albums", value: "\(library.browse.albums.count)")
                LabeledContentRow(label: "Artists", value: "\(library.browse.artistNames.count)")
                LabeledContentRow(label: "Listening Time", value: listeningTime)
            }
            Section("Your Library") {
                LabeledContentRow(label: "Favorites", value: "\(visible.filter(\.favorite).count)")
                LabeledContentRow(label: "Playlists", value: "\(library.playlists.count)")
                LabeledContentRow(label: "Enabled Folders", value: "\(library.sources.filter(\.enabled).count)")
            }
        }.listStyle(.insetGrouped).subtleSeparator().miniPlayerClearance().navigationTitle("Library Statistics").navigationBarTitleDisplayMode(.inline)
    }
    private var listeningTime: String {
        let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.hour, .minute]; formatter.unitsStyle = .abbreviated
        return formatter.string(from: library.visibleTracks.reduce(0) { $0 + max(0, $1.duration) }) ?? "0 min"
    }
}
struct ArtworkStorageView: View {
    var body: some View {
        List { ArtworkCacheSection() }.listStyle(.insetGrouped).subtleSeparator().miniPlayerClearance()
            .navigationTitle("Artwork Cache").navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared by the original Settings layout and the dedicated storage screen.
struct ArtworkCacheSection: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var bytes: Int?
    @State private var confirming = false
    var body: some View {
        Section {
            LabeledContentRow(label: "Artwork Cache", value: bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Calculating…")
            LabeledContentRow(label: "Cache Limit", value: "50 MB")
            if library.clearingArtwork { ProgressView("Clearing artwork…") }
            Button("Clear Artwork Cache", role: .destructive) { confirming = true }.disabled(library.busy || bytes == 0 || bytes == nil)
        } header: { Text("Storage") } footer: {
            Text("Only generated covers are cleared. Your songs, playlists and favorites stay intact. Covers return during the next scan.")
        }
        .task(id: library.scanning) { await refreshSize() }
        .confirmationDialog("Clear artwork cache?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { Task { ThumbnailLoader.shared.clear(); await library.clearArtwork(); await refreshSize() } }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func refreshSize() async {
        let directory = library.artworkDirectory
        bytes = await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
    }
}
struct WhatsNewView: View {
    var body: some View {
        List {
            if let notes = AppReleaseNotes.bundled {
                Section { Text("Cassette \(notes.version)").font(.headline) }
                ForEach(notes.sections.indices, id: \.self) { index in
                    Section(notes.sections[index].title) { ForEach(notes.sections[index].items, id: \.self) { Text($0).font(.subheadline) } }
                }
            } else { Text("Release notes are unavailable for this build.").foregroundColor(.secondary) }
        }.listStyle(.insetGrouped).subtleSeparator().miniPlayerClearance().navigationTitle("What's New").navigationBarTitleDisplayMode(.inline)
    }
}
struct AboutView: View {
    var body: some View {
        List {
            Section { Text("Cassette").font(.title3.bold()); Text(AppIdentity.versionLabel).foregroundColor(.secondary); Text("Native, offline music for your iPod.").font(.subheadline) }
            Section("Privacy") { Label("No accounts or tracking", systemImage: "checkmark.shield"); Text("Your library stays on your device. Music, album artwork and lyrics stay local. Optional artist photos use Wikipedia/Wikimedia: artist names and normal connection information are sent when Artists is opened. Disable Online Artist Photos in Settings to stop lookups. No music files are uploaded.").font(.subheadline).foregroundColor(.secondary) }
            Section("Project") { Link("Cassette on GitHub", destination: AppIdentity.projectURL) }
            Section("Artist Photos") { Text("Free images from Wikimedia, cached offline. Open a photo’s credit from its artist row for the creator, license and original image page.").font(.subheadline).foregroundColor(.secondary) }
            Section("Audio Formats") { Text("Native playback for local audio files. Availability depends on your iOS decoder and file encoding.").font(.subheadline); Text("MP3, M4A/AAC, ALAC, WAV and AIFF are native candidates. FLAC, Ogg and Opus may be unavailable.").font(.subheadline).foregroundColor(.secondary) }
            Section("File Access") { Text("Cassette scans its own Files folder and folders you choose. iOS does not allow unrestricted access to every folder on the device.").font(.subheadline).foregroundColor(.secondary) }
        }.listStyle(.insetGrouped).subtleSeparator().miniPlayerClearance().navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
}
