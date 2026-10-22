import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var query = ""
    var body: some View {
        let matchedSongs = songs
        return Group {
            if query.isEmpty { EmptyLibraryView(symbol: "magnifyingglass", title: "Find your music", detail: "Search songs, artists, albums and playlists on your device.") }
            else {
                List {
                    Section("Songs") { ForEach(matchedSongs) { track in SongRow(track: track) { playback.play(matchedSongs, startingAt: track) } } }
                    Section("Albums") { ForEach(library.browse.albums.filter { matches($0.title) || matches($0.artist) }) { album in NavigationLink(album.title) { AlbumDetailView(album: album) } } }
                    Section("Artists") { ForEach(library.browse.artistNames.filter(matches), id: \.self) { artist in NavigationLink(artist) { SongListView(title: artist, tracks: library.browse.artists[artist] ?? [], artist: artist) } } }
                    Section("Playlists") { ForEach(library.playlists.filter { matches($0.name) }) { playlist in NavigationLink(playlist.name) { PlaylistDetailView(id: playlist.id) } } }
                    if matchedSongs.isEmpty { Text("No matching songs").foregroundColor(.secondary) }
                }.listStyle(.plain).subtleSeparator().miniPlayerClearance()
            }
        }.navigationTitle("Search").searchable(text: $query, prompt: "Songs, artists, albums")
    }
    private func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(query) }
    private var songs: [Track] {
        guard !query.isEmpty else { return [] }
        return library.sortedTracks.filter { matches($0.title) || matches($0.artist) || matches($0.album) }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var creating = false
    var body: some View {
        List {
            NavigationLink { SongListView(title: "Favorites", tracks: library.sortedTracks.filter(\.favorite)) } label: { Label("Favorites", systemImage: "heart.fill").foregroundColor(.pink) }
            ForEach(library.playlists) { playlist in NavigationLink { PlaylistDetailView(id: playlist.id) } label: {
                HStack { Image(systemName: "music.note.list").font(.title2).foregroundColor(.blue).frame(width: 40, height: 44)
                    Text(playlist.name)
                    Spacer(minLength: 8)
                    Text("\(playlist.trackIDs.count)").foregroundColor(.secondary).monospacedDigit()
                }
            } }.onDelete { indices in indices.map { library.playlists[$0] }.forEach(library.deletePlaylist) }
            Button("New Playlist…") { creating = true }
        }.subtleSeparator().miniPlayerClearance().navigationTitle("Playlists").toolbar { EditButton() }
            .sheet(isPresented: $creating) { NameSheet(title: "New Playlist", value: "") { library.createPlaylist($0) } }
    }
}
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    @State var value: String
    var save: (String) -> Void
    var body: some View {
        NavigationView {
            Form { TextField("Playlist name", text: $value) }.background(BackGestureSupport(rootBack: { dismiss() })).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save(value); dismiss() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }.navigationViewStyle(.stack)
    }
}
struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var id: UUID
    @State private var adding = false
    @State private var renaming = false
    private var playlist: MusicPlaylist? { library.playlists.first { $0.id == id } }
    var body: some View {
        List {
            if let playlist = playlist {
                PlayButtons(tracks: playlist.trackIDs.compactMap(library.track))
                ForEach(Array(playlist.trackIDs.enumerated()), id: \.offset) { entry in
                    if let track = library.track(entry.element) { SongRow(track: track) { playback.play(playlist.trackIDs.compactMap(library.track), startingAt: track) } }
                    else { Label("Unavailable song", systemImage: "exclamationmark.triangle").foregroundColor(.secondary) }
                }.onDelete { indices in var changed = playlist; changed.trackIDs.remove(atOffsets: indices); library.changePlaylist(changed) }
                    .onMove { from, to in var changed = playlist; changed.trackIDs.move(fromOffsets: from, toOffset: to); library.changePlaylist(changed) }
                if let missing = playlist.unresolvedPaths, !missing.isEmpty {
                    Section("Unresolved Playlist Entries") { ForEach(Array(missing.enumerated()), id: \.offset) { entry in Text(entry.element).font(.footnote).foregroundColor(.secondary) } }
                }
                if playlist.importedSourceID != nil { Text("Imported from M3U. Rescanning its folder updates this list from the file.").font(.footnote).foregroundColor(.secondary) }
                Button("Add Songs") { adding = true }
                Button("Rename Playlist") { renaming = true }
            }
        }.listStyle(.plain).subtleSeparator().miniPlayerClearance().navigationTitle(playlist?.name ?? "Playlist").toolbar { EditButton() }
            .sheet(isPresented: $adding) { NavigationView { List(library.sortedTracks) { track in Button {
                library.toggleTrack(track.id, in: id)
            } label: {
                HStack {
                    ArtworkView(track: track).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.callout).foregroundColor(.primary).lineLimit(1)
                        Text(track.displayArtist).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    let added = playlist?.trackIDs.contains(track.id) ?? false
                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle").foregroundColor(.blue)
                }.frame(minHeight: 44)
            }
                .accessibilityLabel("\(track.title)\((playlist?.trackIDs.contains(track.id) ?? false) ? ", remove from playlist" : ", add to playlist")")
                .accessibilityValue((playlist?.trackIDs.contains(track.id) ?? false) ? "Added" : "Not added") }.navigationTitle("Add Songs").toolbar { Button("Done") { adding = false } } }.navigationViewStyle(.stack) }
            .sheet(isPresented: $renaming) { NameSheet(title: "Rename Playlist", value: playlist?.name ?? "") { name in if var changed = playlist { changed.name = name; library.changePlaylist(changed) } } }
    }
}

struct SourceSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var removing: MusicSource?
    var body: some View {
        List {
            Section {
                Toggle("Apple Music Library", isOn: Binding(
                    get: { library.appleMusicEnabled },
                    set: { library.setAppleMusicEnabled($0) }
                )).disabled(library.busy)
            } header: {
                Text("Apple Music")
            } footer: {
                Text("Reads local DRM-free songs from your device’s Apple Music library. Cloud-only and DRM-protected tracks are skipped.")
            }
            Section {
                ForEach(library.sources) { source in
                    NavigationLink { SourceDetailView(id: source.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(source.name, systemImage: "folder")
                            Text(source.needsReconnect ? "Reconnect required" : source.enabled ? "Scanning enabled" : "Excluded from scanning").font(.footnote).foregroundColor(.secondary)
                        }
                    }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !source.isOwned { Button("Remove", role: .destructive) { removing = source } }
                    }.contextMenu {
                        Button("Rescan") { library.rescan(only: source.id) }.disabled(library.busy || !source.enabled)
                        if !source.isOwned { Button("Remove from Library", role: .destructive) { removing = source } }
                    }
                }
                Button("Add Music Folder…") { library.pickerRequest = PickerRequest(folders: true) }
                if library.scanning { ScanProgressView() }
            } header: {
                Text("Music Folders")
            } footer: {
                Text("In Files, choose Browse → On My iPod and select a folder. iOS grants access to selected folders, not the entire device. Cassette’s own folder is scanned automatically. Source removal never deletes your audio.")
            }
        }.subtleSeparator().miniPlayerClearance().navigationTitle("Music Folders").alert("Remove this source?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let source = removing { library.removeSource(source) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Your music files stay where they are. Tracks shared with another folder stay accessible.") }
    }
}
struct SourceDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    var id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    private var source: MusicSource? { library.sources.first { $0.id == id } }
    var body: some View {
        List {
            if let source = source {
                Section {
                    Toggle("Scan this folder", isOn: Binding(get: { self.source?.enabled ?? false }, set: { library.setEnabled(id, enabled: $0) })).disabled(library.busy)
                    Button("Rescan Folder") { library.rescan(only: id) }.disabled(library.busy || !source.enabled)
                    if library.scanning { ScanProgressView() }
                    if !source.isOwned { Button("Reconnect Folder…") { library.pickerRequest = PickerRequest(folders: true, reconnecting: id) } }
                } footer: { Text(source.isOwned ? "Files → On My iPod → Cassette. All audio inside this app folder is found automatically; no Music subfolder is required." : "Keep this folder on your device. Cloud-only files are skipped.") }
                Section("Excluded Subfolders") {
                    ForEach(source.excludedPaths, id: \.self) { path in
                        HStack { Text(path).font(.subheadline); Spacer(); Button("Include") { library.includeFolder(id, path: path) }.disabled(library.busy) }
                    }
                    Button("Exclude a Folder…") { library.pickerRequest = PickerRequest(folders: true, excludeFrom: id) }.disabled(library.busy)
                }
                if !source.isOwned {
                    Section {
                        Button("Remove Folder from Library", role: .destructive) { confirmingRemoval = true }
                    } footer: { Text("Removes this folder’s library access only. Your original audio, favorites and playlists are kept.") }
                }
            }
        }.subtleSeparator().miniPlayerClearance().navigationTitle(source?.name ?? "Folder").navigationBarTitleDisplayMode(.inline)
            .alert("Remove this folder?", isPresented: $confirmingRemoval) {
                Button("Remove", role: .destructive) {
                    if let source = source { library.removeSource(source) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your audio files will not be deleted. Any scan in progress will finish cancelling before removal.") }
    }
}


struct AddToPlaylistView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    var track: Track
    @State private var creating = false
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(track: track).frame(width: 48, height: 48)
                        VStack(alignment: .leading) { Text(track.title).font(.headline); Text(track.displayArtist).font(.subheadline).foregroundColor(.secondary) }
                    }
                }
                Section("Playlists") {
                    ForEach(library.playlists) { playlist in
                        let added = playlist.trackIDs.contains(track.id)
                        Button { library.toggleTrack(track.id, in: playlist.id) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(track: playlist.trackIDs.first.flatMap(library.track)).frame(width: 40, height: 40)
                                Text(playlist.name).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle").foregroundColor(.blue)
                            }.frame(minHeight: 44)
                        }.accessibilityLabel("\(playlist.name)\(added ? ", remove song" : ", add song")")
                            .accessibilityValue(added ? "Added" : "Not added")
                    }
                    Button("New Playlist…") { creating = true }
                }
            }.background(BackGestureSupport(rootBack: { dismiss() })).navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $creating) {
                    NameSheet(title: "New Playlist", value: "") { name in
                        library.createPlaylist(name)
                        if let playlist = library.playlists.last { library.addTrack(track.id, to: playlist.id) }
                    }
                }
        }.navigationViewStyle(.stack)
    }
}
