import SwiftUI
import UIKit
import WidgetKit

/// Shared native content for WidgetKit and in-app previews. No timers, blur, network or database access.
struct CassetteWidgetCard: View {
    static let backgroundColor = Color(red: 0.08, green: 0.09, blue: 0.11)
    var snapshot: WidgetSnapshot
    var artwork: UIImage?
    var square: Bool
    var showsBackground: Bool = true
    var body: some View {
        let card = Group {
            if square {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top) {
                        cover(size: 58)
                        Spacer(minLength: 4)
                        brand
                    }
                    Spacer(minLength: 0)
                    Text(snapshot.hasTrack ? "LAST PLAYED" : "YOUR MUSIC").font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.55))
                    Text(snapshot.hasTrack ? snapshot.title : "Cassette").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(snapshot.hasTrack ? snapshot.artist : "Open your library").font(.system(size: 12)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                }.padding(12)
            } else {
                HStack(spacing: 14) {
                    cover(size: 100)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(snapshot.hasTrack ? "LAST PLAYED" : "YOUR MUSIC").font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.55))
                            Spacer(minLength: 0); brand
                        }
                        Text(snapshot.hasTrack ? snapshot.title : "Cassette").font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Text(snapshot.hasTrack ? snapshot.artist : "Music, kept close.").font(.system(size: 12)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                        Spacer(minLength: 0)
                        Label(snapshot.hasTrack ? "Open player" : "Open library", systemImage: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.white.opacity(0.08)).cornerRadius(16)
                    }
                }.padding(14)
            }
        }.foregroundColor(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        Group {
            if showsBackground {
                card.background(Self.backgroundColor)
            } else {
                card
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var brand: some View {
        fullColorImage(Image("CassetteMark")).scaledToFit().frame(width: 20, height: 20).cornerRadius(4).accessibilityHidden(true)
    }
    private func cover(size: CGFloat) -> some View {
        Group {
            if let artwork = artwork {
                fullColorImage(Image(uiImage: artwork)).scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note").font(.system(size: 24, weight: .medium)).foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(9)
        .accessibilityHidden(true)
    }
    @ViewBuilder
    private func fullColorImage(_ image: Image) -> some View {
        if #available(iOS 18.0, iOSApplicationExtension 18.0, *) {
            image.renderingMode(.original).resizable().widgetAccentedRenderingMode(.fullColor)
        } else {
            image.renderingMode(.original).resizable()
        }
    }
}
