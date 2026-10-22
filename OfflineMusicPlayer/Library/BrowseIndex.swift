import Foundation

/// Rebuilt when library data/policy changes, never for playback clock ticks.
struct BrowseIndex {
    let albums: [AlbumGroup]
    let artists: [String: [Track]]
    let genres: [String: [Track]]
    let artistNames: [String]
    let genreNames: [String]
    let recentTracks: [Track]
    let recentAlbums: [AlbumGroup]
    init(tracks: [Track]) {
        albums = AlbumGroup.make(tracks)
        var artistGroups: [String: [Track]] = [:]
        var canonicalNameByLower: [String: String] = [:]
        for track in tracks {
            for artistName in track.artistList {
                let lower = artistName.lowercased()
                let canonical = canonicalNameByLower[lower] ?? {
                    canonicalNameByLower[lower] = artistName
                    return artistName
                }()
                artistGroups[canonical, default: []].append(track)
            }
        }
        artists = artistGroups
        genres = Dictionary(grouping: tracks, by: \.genre)
        artistNames = artists.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        genreNames = genres.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        recentTracks = tracks.sorted { $0.added > $1.added }
        recentAlbums = Array(albums.sorted { $0.added > $1.added }.prefix(8))
    }

    func tracks(forArtist name: String) -> [Track] {
        if let exact = artists[name] { return exact }
        let target = name.lowercased()
        return artists.first(where: { $0.key.lowercased() == target })?.value ?? []
    }
}
