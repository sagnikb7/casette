import SwiftUI
import ImageIO

@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 18_000_000 }
    func image(_ path: String) -> UIImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            let decoded = UIImage(cgImage: cgImage)
            cache.setObject(decoded, forKey: path as NSString, cost: cgImage.width * cgImage.height * 4)
            return decoded
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
    func clear() { cache.removeAllObjects() }
}

struct ArtworkView: View {
    @EnvironmentObject private var library: LibraryStore
    var track: Track?
    var cornerRadius: CGFloat = 6
    /// Crops this many points off every edge of real artwork, hiding faint 1-2px border
    /// artifacts baked into some embedded covers without affecting the placeholder tile.
    var edgeInsetCrop: CGFloat = 0
    var body: some View {
        ZStack {
            if let name = track?.artwork, let image = ThumbnailLoader.shared.image(library.artworkDirectory.appendingPathComponent(name).path) {
                Image(uiImage: image).resizable().scaledToFill().padding(-edgeInsetCrop)
            } else {
                Color(UIColor.secondarySystemBackground)
                Image(systemName: "music.note").font(.system(size: 18, weight: .medium)).foregroundColor(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Shared "Go to Artist" menu control: navigates directly when a song has one artist,
/// or expands a picker submenu of individual artists when a song has multiple artists.
struct GoToArtistMenuItems: View {
    var track: Track
    var selectArtist: (String) -> Void
    var body: some View {
        let artists = track.artistList
        if artists.count > 1 {
            Menu {
                ForEach(artists, id: \.self) { artist in
                    Button {
                        selectArtist(artist)
                    } label: {
                        Label(artist, systemImage: "person.fill")
                    }
                }
            } label: {
                Label("Go to Artist", systemImage: "person.fill")
            }
        } else if let first = artists.first {
            Button("Go to Artist", systemImage: "person.fill") {
                selectArtist(first)
            }
        }
    }
}

struct SongRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var track: Track
    var play: () -> Void
    @State private var destination: PlayerDestination?
    var body: some View {
        let ViewRow = HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ArtworkView(track: track).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.callout).foregroundColor(playback.currentTrack?.id == track.id ? .blue : .primary).lineLimit(1)
                        Text(track.available ? track.displayArtist : "Unavailable · reconnect folder").font(.footnote).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(VisualPressButtonStyle())
            Menu {
                if !track.available, let brokenSource = library.sources.first(where: { src in !src.isOwned && track.locations.contains(where: { $0.sourceID == src.id }) }) {
                    Button("Reconnect \(brokenSource.name)…", systemImage: "folder.badge.gearshape") {
                        library.pickerRequest = PickerRequest(folders: true, reconnecting: brokenSource.id)
                    }
                    Button("Remove Disconnected Folder", systemImage: "trash", role: .destructive) {
                        library.removeSource(brokenSource)
                    }
                    Divider()
                }
                GoToArtistMenuItems(track: track) { destination = .artist($0) }
                Button("Go to Album", systemImage: "square.stack") { destination = .album(track.albumKey) }
                Button("Play Next", systemImage: "text.insert") { playback.playNext(track) }
                Button("Add to Queue", systemImage: "text.badge.plus") { playback.addToQueue(track) }
                Button(track.favorite ? "Remove Favorite" : "Add to Favorites", systemImage: track.favorite ? "heart.slash" : "heart") { library.favorite(track) }
                if !library.playlists.isEmpty {
                    Menu("Add to Playlist") {
                        ForEach(library.playlists) { playlist in
                            Button { library.addTrack(track.id, to: playlist.id) } label: {
                                Label(playlist.name, systemImage: playlist.trackIDs.contains(track.id) ? "checkmark" : "plus")
                            }.disabled(playlist.trackIDs.contains(track.id))
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 44, height: 44) }.accessibilityLabel("More options for \(track.title)")
        }
        return ViewRow.listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8)).subtleSeparator()
            .background {
                NavigationLink(isActive: Binding(get: { destination != nil }, set: { if !$0 { destination = nil } })) {
                    if let destination = destination { SongDestinationContent(destination: destination) }
                } label: { EmptyView() }.hidden()
            }
    }
}

struct SongListView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @AppStorage("artistPhotosEnabled") private var artistPhotosEnabled = true
    var title: String
    var tracks: [Track]
    var artist: String? = nil
    @State private var query = ""
    @State private var sort = "Default"
    @State private var headerVisible = true
    @State private var artistPhoto: ArtistPhoto?
    @State private var bioExpanded = false
    var body: some View {
        let currentFiltered = filtered
        return Group {
            if tracks.isEmpty { EmptyLibraryView(symbol: "music.note", title: "No songs yet", detail: "Add a music folder or import audio files from Library.") }
            else {
                List {
                    Group {
                        if let photo = artistPhoto, let image = ThumbnailLoader.shared.image(photo.fileURL.path) {
                            ArtistHeroHeader(title: title, count: currentFiltered.count, image: image)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                MarqueeText(text: title, font: .largeTitle.weight(.bold))
                                Spacer(minLength: 8)
                                Text("\(currentFiltered.count)").font(.title3).foregroundColor(.secondary).monospacedDigit().layoutPriority(1)
                                    .accessibilityLabel("\(currentFiltered.count) songs")
                            }.padding(.horizontal, 16)
                        }
                    }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .onAppear { headerVisible = true }.onDisappear { headerVisible = false }
                    if artist != nil, let photo = artistPhoto, let summary = photo.summary, !summary.isEmpty {
                        ArtistAboutCard(artist: title, photo: photo, summary: summary, isExpanded: $bioExpanded)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    SongSearchField(text: $query, placeholder: "Search songs").frame(height: 52)
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    PlayButtons(tracks: currentFiltered).listRowSeparator(.hidden)
                    ForEach(currentFiltered) { track in SongRow(track: track) { playback.play(currentFiltered, startingAt: track) } }
                }.listStyle(.plain).miniPlayerClearance()
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text(title).font(.headline).lineLimit(1).opacity(headerVisible || tracks.isEmpty ? 0 : 1) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !tracks.isEmpty {
                        Menu {
                            Picker("Sort", selection: $sort) { Text("Default").tag("Default"); Text("Title").tag("Title"); Text("Artist").tag("Artist") }
                        } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("Sort songs, \(sort)")
                    }
                }
            }
            .task(id: "\(artist ?? ""):\(artistPhotosEnabled)") {
                artistPhoto = nil
                bioExpanded = false
                guard let artistName = artist, artistPhotosEnabled else { return }
                // Load cached/base photo first so the 600x600 hero appears immediately, then lazily enrich details.
                if let initial = await ArtistPhotoStore.shared.photo(for: artistName, includeDetails: false), !Task.isCancelled {
                    artistPhoto = initial
                }
                let detailed = await ArtistPhotoStore.shared.photo(for: artistName, includeDetails: true)
                if !Task.isCancelled { artistPhoto = detailed }
            }
    }
    private var filtered: [Track] {
        let result: [Track]
        if query.isEmpty {
            result = tracks
        } else {
            result = tracks.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.artist.localizedCaseInsensitiveContains(query) ||
                $0.album.localizedCaseInsensitiveContains(query)
            }
        }
        if sort == "Title" { return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        if sort == "Artist" { return result.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending } }
        return result
    }
}

struct ArtistAboutCard: View {
    var artist: String
    var photo: ArtistPhoto
    var summary: String
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var pills: [(String, String)] {
        var items: [(String, String)] = []
        if let genre = photo.genre, !genre.isEmpty { items.append(("guitars", genre)) }
        if let origin = photo.origin, !origin.isEmpty { items.append(("mappin.and.ellipse", origin)) }
        if let span = photo.lifeSpan, !span.isEmpty { items.append(("calendar", span)) }
        return items
    }
    var body: some View {
        Button {
            if reduceMotion { isExpanded.toggle() }
            else { withAnimation(.spring(response: 0.36, dampingFraction: 0.84, blendDuration: 0.1)) { isExpanded.toggle() } }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text("About \(artist)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(isExpanded ? "LESS" : "MORE")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
                if !pills.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                                Label(pill.1, systemImage: pill.0)
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                Text(summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isExpanded {
                    if let tags = photo.tags, !tags.isEmpty {
                        Text("Styles: " + tags.prefix(5).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("Source: Apple Music / iTunes & MusicBrainz")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(VisualPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("About \(artist). \(summary)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand") artist description")
    }
}

private struct ArtistHeroHeader: View {
    var title: String
    var count: Int
    var image: UIImage
    var body: some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 250).clipped()
            LinearGradient(
                colors: [.clear, Color(UIColor.systemBackground).opacity(0.3), Color(UIColor.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MarqueeText(text: title, font: .largeTitle.weight(.bold))
                Text("\(count)").font(.title3).foregroundColor(.secondary).monospacedDigit().fixedSize().layoutPriority(2)
                    .accessibilityLabel("\(count) songs")
            }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity).frame(height: 250)
        .accessibilityElement(children: .contain)
    }
}

/// Native-looking minimal search bar that sits inside the list, under the title.
struct SongSearchField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = placeholder
        bar.autocapitalizationType = .none
        bar.delegate = context.coordinator
        return bar
    }
    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.parent = self
        if bar.text != text { bar.text = text }
    }
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SongSearchField
        init(_ parent: SongSearchField) { self.parent = parent }
        func searchBar(_ bar: UISearchBar, textDidChange searchText: String) { parent.text = searchText }
        func searchBarSearchButtonClicked(_ bar: UISearchBar) { bar.resignFirstResponder() }
        func searchBarTextDidBeginEditing(_ bar: UISearchBar) { bar.setShowsCancelButton(true, animated: true) }
        func searchBarTextDidEndEditing(_ bar: UISearchBar) { bar.setShowsCancelButton(false, animated: true) }
        func searchBarCancelButtonClicked(_ bar: UISearchBar) { parent.text = ""; bar.text = ""; bar.resignFirstResponder() }
    }
}

struct PlayButtons: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    var tracks: [Track]
    var body: some View {
        HStack(spacing: 12) {
            Button { playback.play(tracks) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 36) }
            Button { playback.play(tracks, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 36) }
        }.buttonStyle(.bordered).disabled(!tracks.contains(where: \.available))
    }
}

struct AlbumGroup: Identifiable {
    var id: String
    var title: String
    var artist: String
    var tracks: [Track]
    var added: Date
    init(id: String, title: String, artist: String, tracks: [Track]) {
        self.id = id
        self.title = title
        self.artist = Track.parseArtists(artist).joined(separator: ", ")
        self.tracks = tracks
        self.added = tracks.map(\.added).max() ?? .distantPast
    }
    static func make(_ tracks: [Track]) -> [AlbumGroup] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, tracks in
            AlbumGroup(id: key, title: tracks[0].album, artist: tracks[0].albumArtist,
                       tracks: tracks.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
struct AlbumTile: View {
    var album: AlbumGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ArtworkView(track: album.tracks.first).aspectRatio(1, contentMode: .fit)
            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundColor(.primary)
            Text(album.artist).font(.footnote).lineLimit(1).foregroundColor(.secondary)
        }
    }
}
struct AlbumsView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        ScrollView { LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 16) {
            ForEach(library.browse.albums) { album in NavigationLink { AlbumDetailView(album: album) } label: { AlbumTile(album: album) }.buttonStyle(.plain) }
        }.padding(16) }.miniPlayerClearance().navigationTitle("Albums")
    }
}
struct AlbumDetailView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    var album: AlbumGroup
    var body: some View {
        List {
            VStack(spacing: 12) {
                ArtworkView(track: album.tracks.first).frame(width: 148, height: 148)
                Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(album.artist).foregroundColor(.blue)
                Text("\(album.tracks.count) songs").font(.caption).foregroundColor(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 12).listRowSeparator(.hidden)
            PlayButtons(tracks: album.tracks)
            ForEach(album.tracks) { track in SongRow(track: track) { playback.play(album.tracks, startingAt: track) } }
        }.listStyle(.plain).miniPlayerClearance().navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
    }
}
struct GroupsView: View {
    enum Kind { case artist, genre }
    @EnvironmentObject private var library: LibraryStore
    var kind: Kind
    var body: some View {
        List(groups, id: \.self) { group in
            let tracks = (kind == .artist ? library.browse.artists[group] : library.browse.genres[group]) ?? []
            NavigationLink { SongListView(title: group, tracks: tracks, artist: kind == .artist ? group : nil) } label: {
                if kind == .artist { ArtistGroupRow(artist: group, count: tracks.count) }
                else {
                    HStack { Image(systemName: "waveform").foregroundColor(.blue).frame(width: 32)
                        VStack(alignment: .leading) { Text(group); Text("\(tracks.count) songs").font(.footnote).foregroundColor(.secondary) }
                    }.frame(minHeight: 44)
                }
            }.subtleSeparator()
        }.listStyle(.plain).miniPlayerClearance().navigationTitle(kind == .artist ? "Artists" : "Genres")
    }
    private var groups: [String] { kind == .artist ? library.browse.artistNames : library.browse.genreNames }
}

struct FoldersView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var removing: MusicSource?
    var body: some View {
        let counts: [UUID: Int] = library.visibleTracks.reduce(into: [:]) { acc, track in
            for location in track.locations where location.available { acc[location.sourceID, default: 0] += 1 }
        }
        return List {
            ForEach(library.sources) { source in
                HStack {
                    NavigationLink { FolderContentsView(source: source, path: "") } label: {
                        HStack {
                            Image(systemName: source.needsReconnect ? "exclamationmark.triangle.fill" : "folder.fill")
                                .foregroundColor(source.needsReconnect ? .orange : .blue).frame(width: 32)
                            VStack(alignment: .leading) {
                                Text(source.name)
                                Text(source.needsReconnect ? "Reconnect required" : "\(counts[source.id, default: 0]) songs")
                                    .font(.footnote).foregroundColor(source.needsReconnect ? .orange : .secondary)
                            }
                        }.frame(minHeight: 44)
                    }
                    if source.needsReconnect && !source.isOwned {
                        Button("Reconnect") {
                            library.pickerRequest = PickerRequest(folders: true, reconnecting: source.id)
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !source.isOwned { Button("Remove", role: .destructive) { removing = source } }
                }
                .contextMenu {
                    if !source.isOwned && source.needsReconnect {
                        Button("Reconnect Folder…") { library.pickerRequest = PickerRequest(folders: true, reconnecting: source.id) }
                    }
                    Button("Rescan") { library.rescan(only: source.id) }.disabled(library.busy || !source.enabled)
                    if !source.isOwned { Button("Remove from Library", role: .destructive) { removing = source } }
                }
                .subtleSeparator()
            }
            Button("Add Music Folder…") { library.pickerRequest = PickerRequest(folders: true) }.subtleSeparator()
        }.miniPlayerClearance().navigationTitle("Folders")
        .alert("Remove this folder?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let source = removing { library.removeSource(source) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Your music files stay where they are. Disconnected duplicate entries from this folder will be cleared.") }
    }
}
struct FolderContentsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var source: MusicSource
    var path: String
    var body: some View {
        let currentEntries: [(Track, String)] = library.sortedTracks.compactMap { track in
            guard let location = track.locations.first(where: { $0.sourceID == source.id }), location.relativePath.hasPrefix(path) else { return nil }
            return (track, String(location.relativePath.dropFirst(path.count)))
        }
        let folders = Set(currentEntries.compactMap { $0.1.contains("/") ? $0.1.components(separatedBy: "/").first : nil }).sorted()
        let songs = currentEntries.filter { !$0.1.contains("/") }.map { $0.0 }
        return List {
            ForEach(folders, id: \.self) { folder in NavigationLink { FolderContentsView(source: source, path: path + folder + "/") } label: { Label(folder, systemImage: "folder") }.subtleSeparator() }
            if !songs.isEmpty { PlayButtons(tracks: songs) }
            ForEach(songs) { track in SongRow(track: track) { playback.play(songs, startingAt: track) } }
            if currentEntries.isEmpty { Text("No indexed audio in this folder.").foregroundColor(.secondary) }
        }.listStyle(.plain).miniPlayerClearance().navigationTitle(path.isEmpty ? source.name : String(path.dropLast()).components(separatedBy: "/").last ?? source.name).navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared destinations keep song menus consistent across albums, playlists, search and the player.
struct SongDestinationContent: View {
    @EnvironmentObject private var library: LibraryStore
    var destination: PlayerDestination
    @ViewBuilder var body: some View {
        switch destination {
        case .artist(let name): SongListView(title: name, tracks: library.browse.tracks(forArtist: name), artist: name)
        case .album(let key):
            if let album = library.browse.albums.first(where: { $0.id == key }) { AlbumDetailView(album: album) }
            else { Text("Album is unavailable") }
        }
    }
}


struct RecentlyPlayedTile: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    var track: Track
    var body: some View {
        Button { playback.play([track]) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ArtworkView(track: track).aspectRatio(1, contentMode: .fit)
                Text(track.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1)
                Text(track.displayArtist).font(.footnote).foregroundColor(.secondary).lineLimit(1)
            }
        }.buttonStyle(.plain).accessibilityLabel("Play \(track.title) by \(track.displayArtist)")
    }
}

struct ListeningHistoryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var body: some View {
        Group {
            if library.historySongs.isEmpty {
                EmptyLibraryView(symbol: "clock", title: "No listening history yet", detail: "Songs you play will appear here, with the most recent first.")
            } else {
                List {
                    ForEach(library.historySongs) { song in
                        VStack(alignment: .leading, spacing: 2) {
                            SongRow(track: song.track) { playback.play([song.track]) }
                            Text(song.entry.playedAt, style: .date) + Text(" · ") + Text(song.entry.playedAt, style: .time)
                        }.font(.caption).foregroundColor(.secondary).subtleSeparator()
                    }
                }.listStyle(.plain).miniPlayerClearance()
            }
        }.navigationTitle("Listening History").navigationBarTitleDisplayMode(.inline)
    }
}
