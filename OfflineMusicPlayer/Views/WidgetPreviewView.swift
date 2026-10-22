import SwiftUI

struct WidgetPreviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your music, at a glance.").font(.headline)
                Text("Both sizes open the player when tapped. iOS 15 widgets do not play or pause music without opening the app.").font(.subheadline).foregroundColor(.secondary)
                Text("Square").font(.footnote.weight(.semibold))
                CassetteWidgetCard(snapshot: snapshot, artwork: image, square: true).frame(width: 141, height: 141).cornerRadius(22)
                Text("Horizontal").font(.footnote.weight(.semibold))
                CassetteWidgetCard(snapshot: snapshot, artwork: image, square: false).frame(maxWidth: 329).frame(height: 141).cornerRadius(22)
                Text("Widget status").font(.headline)
                if let status = playback.widgetStatus { Text(status).font(.footnote).foregroundColor(.secondary) }
                Button("Refresh Widgets") { playback.refreshWidgets() }.buttonStyle(.bordered)
                Text("If a widget stays blank after refreshing, remove it from the Home Screen and add it again. Removing a widget does not delete music.").font(.footnote).foregroundColor(.secondary)
                Text("Add a widget").font(.headline)
                Text("Touch and hold the Home Screen, tap +, find Cassette, then choose the square or horizontal size.").font(.subheadline)
                Text("Artwork and track details need both the app and widget signed with the same App Group. A preview here does not confirm widget installation or signing.").font(.footnote).foregroundColor(.secondary)
            }.padding(16)
        }.navigationTitle("Widgets").navigationBarTitleDisplayMode(.inline)
    }
    private var displayedTrack: Track? { playback.currentTrack ?? library.recentlyPlayed.first?.track }
    private var snapshot: WidgetSnapshot { WidgetSnapshot(title: displayedTrack?.title ?? "", artist: displayedTrack?.displayArtist ?? "", artworkName: nil) }
    private var image: UIImage? { displayedTrack?.artwork.flatMap { ThumbnailLoader.shared.image(library.artworkDirectory.appendingPathComponent($0).path) } }
}
