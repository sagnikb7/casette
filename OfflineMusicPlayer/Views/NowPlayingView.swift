import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showingPlayer: Bool
    var animationNamespace: Namespace.ID? = nil
    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingPlayer = true
            } label: {
                HStack(spacing: 10) {
                    miniArtwork
                    Text(playback.title ?? "").font(.subheadline).lineLimit(1).foregroundColor(.primary)
                    Spacer(minLength: 0)
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(VisualPressButtonStyle()).accessibilityLabel("Open Now Playing")
            Button { playback.toggle() } label: { Image(systemName: (playback.playbackRequested || playback.isPlaying) ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 52, height: 52) }.accessibilityLabel((playback.playbackRequested || playback.isPlaying) ? "Pause" : "Play")
            SeekTransportButton(symbol: "forward.fill", label: "Next song", pointSize: 17, tap: { playback.next() }, seek: { playback.seek(to: playback.position + 2) }).frame(width: 52, height: 52)
        }.buttonStyle(VisualPressButtonStyle()).padding(.horizontal, 12).background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
    }
    @ViewBuilder private var miniArtwork: some View {
        if let namespace = animationNamespace, !reduceMotion {
            if !showingPlayer {
                ArtworkView(track: playback.currentTrack)
                    .matchedGeometryEffect(id: "playerArtwork", in: namespace)
                    .frame(width: 36, height: 36)
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        } else {
            ArtworkView(track: playback.currentTrack).frame(width: 36, height: 36)
        }
    }
}

enum PlayerDestination: Identifiable {
    case artist(String), album(String)
    var id: String { switch self { case .artist(let name): return "artist:" + name; case .album(let key): return "album:" + key } }
}

enum NowPlayingMode { case artwork, queue, lyrics }

/// Rounds only the top-left/top-right corners, matching Apple Music's sheet card.
/// (SwiftUI's UnevenRoundedRectangle requires iOS 16+; this project's minimum is iOS 15.)
private struct TopRoundedRectangle: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        guard radius > 0 else { return Rectangle().path(in: rect) }
        let bezier = UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: radius, height: radius))
        return Path(bezier.cgPath)
    }
}

/// Animates only the non-artwork chrome (header, controls, background card) during sheet
/// insertion/removal and interactive vertical drag so matchedGeometryEffect("playerArtwork")
/// can morph the album art directly between its Now Playing frame and the 36x36 MiniPlayer slot
/// without a parent .move(edge: .bottom) or .offset(y:) fighting or leaving the view stuck mid-screen.
private struct SheetChromeSlideModifier: ViewModifier {
    var dragOffset: CGFloat
    var yMultiplier: CGFloat = 1.0
    var extraTransitionY: CGFloat = 0
    func body(content: Content) -> some View {
        content.offset(y: max(0, dragOffset) * yMultiplier + extraTransitionY)
    }
}

private extension AnyTransition {
    static func sheetChromeSlide(distance: CGFloat = 140) -> AnyTransition {
        .modifier(
            active: SheetChromeSlideModifier(dragOffset: 0, extraTransitionY: distance),
            identity: SheetChromeSlideModifier(dragOffset: 0, extraTransitionY: 0)
        ).combined(with: .opacity)
    }
}

struct NowPlayingView: View {
    var initialMode: NowPlayingMode = .artwork
    var animationNamespace: Namespace.ID? = nil
    var dismissDragOffset: Binding<CGFloat>? = nil
    var onDismiss: (() -> Void)? = nil
    @State private var standaloneDragOffset: CGFloat = 0
    var body: some View {
        NowPlayingContent(
            initialMode: initialMode,
            animationNamespace: animationNamespace,
            dismissDragOffset: dismissDragOffset ?? $standaloneDragOffset,
            onDismiss: onDismiss
        )
    }
}

private struct NowPlayingContent: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: NowPlayingMode
    private var secondaryTextColor: Color {
        colorScheme == .dark ? .secondary : Color.primary.opacity(0.72)
    }
    var animationNamespace: Namespace.ID?
    @Binding var dismissDragOffset: CGFloat
    var onDismiss: (() -> Void)?
    init(initialMode: NowPlayingMode, animationNamespace: Namespace.ID?, dismissDragOffset: Binding<CGFloat>, onDismiss: (() -> Void)?) {
        _mode = State(initialValue: initialMode)
        self.animationNamespace = animationNamespace
        self._dismissDragOffset = dismissDragOffset
        self.onDismiss = onDismiss
    }
    @State private var showingSleepTimer = false
    @State private var dragOffset: CGFloat = 0
    @State private var artworkTransitioning = false
    @State private var playlistTrack: Track?
    @State private var destination: PlayerDestination?
    @State private var lyricLines: [LyricLine] = []

    private func closePlayer() {
        if let onDismiss = onDismiss { onDismiss() }
        else { dismiss() }
    }

    /// How far through a dismiss drag the user has pulled, 0 (resting) to 1 (ready to release).
    private var dismissProgress: CGFloat {
        guard dismissDragOffset > 0 else { return 0 }
        return min(1, dismissDragOffset / 280)
    }
    private var dismissScrimOpacity: Double { 0.38 * Double(1 - dismissProgress) }
    private var sheetCornerRadius: CGFloat { dismissDragOffset > 0 ? 32 : 0 }

    /// Finalizes a vertical dismiss drag: either hands off to the spring-driven sheet
    /// collapse/MiniPlayer morph (animating dismissDragOffset back to 0 within the same
    /// RootView.playerSpring transaction so matchedGeometryEffect interpolates from the exact
    /// finger-release position without double-offsetting or leaving stale drag state on reopen)
    /// or snaps back open.
    private func finishDismissDrag(_ value: DragGesture.Value) {
        let projectedY = max(value.translation.height, value.predictedEndTranslation.height * 0.45)
        if projectedY > 110 {
            if reduceMotion {
                dismissDragOffset = 0
                closePlayer()
            } else {
                withAnimation(RootView.playerSpring) {
                    dismissDragOffset = 0
                    closePlayer()
                }
            }
        } else {
            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.88, blendDuration: 0.1)) {
                dismissDragOffset = 0
            }
        }
    }

    private var sheetDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !artworkTransitioning, value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else { return }
                dragOffset = 0
                dismissDragOffset = rubberBanded(value.translation.height, dimension: UIScreen.main.bounds.height)
            }
            .onEnded { value in
                guard dismissDragOffset > 0 else { return }
                finishDismissDrag(value)
            }
    }

    private var grabber: some View {
        Capsule().fill(Color.primary.opacity(0.28)).frame(width: 36, height: 5)
            .padding(.top, 5).padding(.bottom, 0)
            .accessibilityHidden(true)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(reduceMotion ? 0 : dismissScrimOpacity).ignoresSafeArea().allowsHitTesting(false)
            sheet
        }
        .buttonStyle(VisualPressButtonStyle())
        .background(BackGestureSupport(rootBack: { closePlayer() }))
        .onAppear {
            dismissDragOffset = 0
            playback.setPlayerVisible(true)
            playback.setLyricsTracking(mode == .lyrics && !lyricLines.isEmpty)
        }
        .onChange(of: mode) { playback.setLyricsTracking($0 == .lyrics && !lyricLines.isEmpty) }
        .onChange(of: lyricLines) { playback.setLyricsTracking(mode == .lyrics && !$0.isEmpty) }
        .onDisappear { playback.setPlayerVisible(false) }
        .task(id: lyricFingerprint) {
            lyricLines = []
            let text = currentTrack?.lyrics ?? ""
            let parsed = await Task.detached(priority: .utility) { LRCParser.parse(text) }.value
            if !Task.isCancelled { lyricLines = parsed }
        }
        .fullScreenCover(item: $destination) { route in
            NavigationView {
                SongDestinationContent(destination: route).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back to Player") { destination = nil } } }
                    .background(BackGestureSupport(rootBack: { destination = nil }))
            }.navigationViewStyle(.stack)
        }
        .sheet(isPresented: $showingSleepTimer) { SleepTimerView(clock: playback.clock).environmentObject(playback) }
        .sheet(item: $playlistTrack) { track in
            AddToPlaylistView(track: track).environmentObject(library)
        }
    }

    private var sheet: some View {
        ZStack {
            ArtworkSurface(
                artworkURL: currentTrack?.artwork.map { library.artworkDirectory.appendingPathComponent($0) },
                revision: library.artworkRevision
            )
                .clipShape(TopRoundedRectangle(radius: reduceMotion ? 0 : sheetCornerRadius))
                .modifier(SheetChromeSlideModifier(dragOffset: dismissDragOffset))
                .transition(reduceMotion ? .opacity : .sheetChromeSlide(distance: 220))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                if !reduceMotion {
                    grabber
                        .modifier(SheetChromeSlideModifier(dragOffset: dismissDragOffset))
                        .transition(.sheetChromeSlide(distance: 100))
                        .simultaneousGesture(sheetDismissGesture)
                }
                header.padding(.horizontal, 24)
                    .modifier(SheetChromeSlideModifier(dragOffset: dismissDragOffset))
                    .transition(reduceMotion ? .opacity : .sheetChromeSlide(distance: 100))
                    .simultaneousGesture(sheetDismissGesture)
                GeometryReader { geometry in
                    ZStack {
                        if mode == .artwork {
                            // Artwork gets 16-point side margins; the controls retain their 24-point margins.
                            // Reserve vertical breathing room so the playing scale (0.92x) and drop shadow
                            // stay completely clear of the song title below while framing the cover cleanly.
                            let side = max(0, min(geometry.size.width - 32, geometry.size.height - 28))
                            playerArtwork(side: side)
                                .offset(x: dragOffset, y: max(0, dismissDragOffset) * 0.65)
                                .opacity(1 - min(0.5, abs(dragOffset) / max(1, geometry.size.width) * 0.8))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { playback.toggle() }
                                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                                    .onChanged { value in
                                        guard !artworkTransitioning, value.startLocation.x > 32 else { return }
                                        if abs(value.translation.width) > abs(value.translation.height) {
                                            dismissDragOffset = 0
                                            dragOffset = rubberBanded(value.translation.width, dimension: geometry.size.width)
                                        } else if value.translation.height > 0 {
                                            dragOffset = 0
                                            dismissDragOffset = rubberBanded(value.translation.height, dimension: geometry.size.height)
                                        }
                                    }
                                    .onEnded { value in
                                        if dismissDragOffset > 0 || (value.translation.height > abs(value.translation.width) * 1.25 && value.translation.height > 0) {
                                            finishDismissDrag(value)
                                            return
                                        }
                                        let width = geometry.size.width
                                        let horizontal = !artworkTransitioning && value.startLocation.x > 32 &&
                                            abs(value.translation.width) > abs(value.translation.height) * 1.25
                                        let projected = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
                                            ? value.predictedEndTranslation.width : value.translation.width
                                        // Require a deliberate pull or a genuinely fast flick. Short releases
                                        // settle without the pronounced back-and-forth of a loose spring.
                                        guard horizontal, max(abs(value.translation.width), abs(projected) * 0.45) > 110 else {
                                            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.92, blendDuration: 0.1)) {
                                                dragOffset = 0
                                            }
                                            return
                                        }
                                        let forward = projected < 0
                                        if reduceMotion {
                                            dragOffset = 0
                                            if forward { playback.next() } else { playback.previousTrack() }
                                            return
                                        }
                                        artworkTransitioning = true
                                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.1)) {
                                            dragOffset = forward ? -(width + side) : width + side
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                                            if forward { playback.next() } else { playback.previousTrack() }
                                            dragOffset = forward ? width : -width
                                            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.1)) {
                                                dragOffset = 0
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                                                artworkTransitioning = false
                                            }
                                        }
                                    })
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else if mode == .queue {
                            queueView.padding(.horizontal, 24).clipped()
                                .modifier(SheetChromeSlideModifier(dragOffset: dismissDragOffset))
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else {
                            lyricsView.padding(.horizontal, 24).clipped()
                                .modifier(SheetChromeSlideModifier(dragOffset: dismissDragOffset))
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86, blendDuration: 0.1), value: mode)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).zIndex(1)
                // This dock is outside every ScrollView. Artwork/lyrics yield space first.
                controlDock.padding(.horizontal, 24)
                    .modifier(SheetChromeSlideModifier(dragOffset: dismissDragOffset))
                    .transition(reduceMotion ? .opacity : .sheetChromeSlide(distance: 160))
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .global)
                            .onChanged { value in
                                guard !artworkTransitioning, value.translation.height > 12,
                                      value.translation.height > abs(value.translation.width) * 1.6 else { return }
                                dragOffset = 0
                                dismissDragOffset = rubberBanded(value.translation.height, dimension: UIScreen.main.bounds.height)
                            }
                            .onEnded { value in
                                guard dismissDragOffset > 0 else { return }
                                finishDismissDrag(value)
                            }
                    )
            }
        }
    }

    @ViewBuilder private func playerArtwork(side: CGFloat) -> some View {
        let view = PlaybackArtworkView(
            reduceMotion: reduceMotion,
            track: currentTrack,
            side: side,
            isPlaying: playback.playbackRequested || playback.isPlaying,
            cornerRadius: 10
        )
        if let namespace = animationNamespace, !reduceMotion {
            view.matchedGeometryEffect(id: "playerArtwork", in: namespace)
        } else {
            view
        }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("NOW PLAYING").font(.caption2.weight(.semibold)).foregroundColor(secondaryTextColor)
                if let album = currentTrack?.album, !album.isEmpty {
                    Text(album).font(.footnote.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .padding(.horizontal, 52)
            HStack(spacing: 0) {
                Button { closePlayer() } label: {
                    Image(systemName: "chevron.down").font(.body.weight(.semibold)).foregroundColor(.primary)
                        .frame(width: 44, height: 44, alignment: .leading).contentShape(Rectangle())
                }.accessibilityLabel("Dismiss Now Playing")
                Spacer(minLength: 0)
            }
        }.frame(minHeight: 44)
    }

    private var metadata: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: playback.title ?? "Nothing playing", font: .title3.weight(.semibold))
                if let track = currentTrack {
                    artistRow(for: track)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).clipped()
            Menu {
                if let track = currentTrack {
                    GoToArtistMenuItems(track: track) { destination = .artist($0) }
                    Button("Go to Album", systemImage: "square.stack") { destination = .album(track.albumKey) }
                }
                Button("Add to Playlist", systemImage: "text.badge.plus") { playlistTrack = currentTrack }
                    .disabled(currentTrack == nil)
                Button(playback.sleepTimerLabel, systemImage: playback.sleepTimerMode == nil ? "moon" : "moon.fill") { showingSleepTimer = true }
            } label: {
                Image(systemName: "ellipsis").font(.title3).foregroundColor(.primary)
                    .frame(width: 44, height: 46, alignment: .trailing).contentShape(Rectangle())
            }
            .frame(width: 44, height: 46, alignment: .trailing)
            .fixedSize()
            .accessibilityLabel("Song options")
        }.frame(minHeight: 46)
    }

    @ViewBuilder private func artistRow(for track: Track) -> some View {
        let artists = track.artistList
        if artists.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(artists.enumerated()), id: \.offset) { index, name in
                        Button {
                            destination = .artist(name)
                        } label: {
                            Text(name).font(.subheadline.weight(.medium)).foregroundColor(secondaryTextColor).lineLimit(1)
                        }.buttonStyle(VisualPressButtonStyle())
                        if index < artists.count - 1 {
                            Text(", ").font(.subheadline.weight(.medium)).foregroundColor(secondaryTextColor)
                        }
                    }
                }
            }
        } else {
            Button {
                if let first = artists.first { destination = .artist(first) }
            } label: {
                Text(track.displayArtist).font(.subheadline.weight(.medium)).foregroundColor(secondaryTextColor).lineLimit(1)
            }.buttonStyle(VisualPressButtonStyle())
        }
    }
    private var currentTrack: Track? { playback.currentTrack.flatMap { library.track($0.id) } ?? playback.currentTrack }
    private func rubberBanded(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let dimension = max(1, dimension)
        let magnitude = abs(distance)
        let resisted = (1 - 1 / ((magnitude * 0.55 / dimension) + 1)) * dimension
        return distance < 0 ? -resisted : resisted
    }
    private var lyricFingerprint: String? { currentTrack.map { $0.id + ":" + $0.fingerprint } }
    private var isFavorite: Bool { currentTrack.flatMap { library.track($0.id) }?.favorite ?? false }
    private var controlDock: some View {
        VStack(spacing: 2) {
            metadata
            PlaybackProgressSection(clock: playback.clock, duration: playback.duration, seek: playback.seek)
            HStack(spacing: 0) {
                SeekTransportButton(symbol: "backward.fill", label: "Previous song", tap: { playback.previous() }, seek: { playback.seek(to: playback.position - 2) }).frame(maxWidth: .infinity).frame(height: 58)
                Button { playback.toggle() } label: { Image(systemName: (playback.playbackRequested || playback.isPlaying) ? "pause.fill" : "play.fill").font(.system(size: 36)).frame(maxWidth: .infinity, minHeight: 58).contentShape(Rectangle()) }.accessibilityLabel((playback.playbackRequested || playback.isPlaying) ? "Pause" : "Play")
                SeekTransportButton(symbol: "forward.fill", label: "Next song", tap: { playback.next() }, seek: { playback.seek(to: playback.position + 2) }).frame(maxWidth: .infinity).frame(height: 58)
            }.foregroundColor(.primary)
            HStack(spacing: 0) {
                Button {
                    if reduceMotion { mode = mode == .lyrics ? .artwork : .lyrics }
                    else { withAnimation(.spring(response: 0.35, dampingFraction: 0.86, blendDuration: 0.1)) { mode = mode == .lyrics ? .artwork : .lyrics } }
                } label: {
                    Image(systemName: "quote.bubble").font(.title3).foregroundColor(mode == .lyrics ? .blue : secondaryTextColor)
                        .padding(8).background(mode == .lyrics ? Color.blue.opacity(0.12) : Color.clear).cornerRadius(10)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: mode)
                        .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                }.accessibilityLabel(mode == .lyrics ? "Hide lyrics" : "Show lyrics").accessibilityValue(mode == .lyrics ? "Selected" : "")
                Button {
                    if let current = currentTrack, let track = library.track(current.id) { library.favorite(track) }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart").font(.title3).foregroundColor(isFavorite ? .blue : secondaryTextColor)
                        .scaleEffect(isFavorite && !reduceMotion ? 1.12 : 1)
                        .padding(8).background(isFavorite ? Color.blue.opacity(0.12) : Color.clear).cornerRadius(10)
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.6), value: isFavorite)
                        .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                }.disabled(currentTrack == nil).accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                Button {
                    if reduceMotion { mode = mode == .queue ? .artwork : .queue }
                    else { withAnimation(.spring(response: 0.35, dampingFraction: 0.86, blendDuration: 0.1)) { mode = mode == .queue ? .artwork : .queue } }
                } label: {
                    Image(systemName: "list.bullet").font(.title3).foregroundColor(mode == .queue ? .blue : secondaryTextColor)
                        .padding(8).background(mode == .queue ? Color.blue.opacity(0.12) : Color.clear).cornerRadius(10)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: mode)
                        .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                }.accessibilityLabel(mode == .queue ? "Hide playing queue" : "Show playing queue").accessibilityValue(mode == .queue ? "Selected" : "")
            }
            if let track = currentTrack {
                Text(track.audioQualityLabel).font(.caption2.weight(.medium)).foregroundColor(secondaryTextColor)
                    .lineLimit(1).frame(maxWidth: .infinity).accessibilityLabel("Audio quality: " + track.audioQualityLabel)
            }
        }.buttonStyle(VisualPressButtonStyle()).fixedSize(horizontal: false, vertical: true).padding(.top, 2).padding(.bottom, 6)
    }
    private var queueView: some View {
        let startIndex = min(playback.queue.count, playback.queueIndex + 1)
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("Playing Next").font(.headline)
                Spacer(minLength: 4)
                Button { playback.toggleShuffle() } label: {
                    Image(systemName: "shuffle").frame(width: 52, height: 52).contentShape(Rectangle()).foregroundColor(playback.shuffle ? .blue : secondaryTextColor)
                }.accessibilityLabel(playback.shuffle ? "Turn shuffle off" : "Turn shuffle on").accessibilityValue(playback.shuffle ? "On" : "Off")
                Button { playback.cycleRepeat() } label: {
                    Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 44, height: 52, alignment: .trailing).contentShape(Rectangle()).foregroundColor(playback.repeatMode == .off ? secondaryTextColor : .blue)
                }.accessibilityLabel("Repeat \(playback.repeatMode.rawValue)")
            }.buttonStyle(VisualPressButtonStyle())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(startIndex..<playback.queue.count, id: \.self) { offset in
                        if let track = library.track(playback.queue[offset]) {
                            Button { playback.jump(to: offset) } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(track: track).frame(width: 36, height: 36)
                                    Text(track.title).foregroundColor(.primary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(VisualPressButtonStyle())
                        }
                    }
                    if startIndex >= playback.queue.count { Text("Nothing queued").foregroundColor(secondaryTextColor).padding(.vertical, 8) }
                }
            }
        }
    }
    @ViewBuilder private var lyricsView: some View {
        if let lyrics = currentTrack?.lyrics, !lyrics.isEmpty {
            if lyricLines.isEmpty {
                ScrollView {
                    Text(lyrics)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.body)
                        .padding(.vertical, 20)
                        .textSelection(.enabled)
                }
                .lyricsEdgeFade()
            } else {
                SyncedLyricsContainer(clock: playback.clock, lines: lyricLines, seek: playback.seek).id(lyricFingerprint)
            }
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "quote.bubble").font(.title2).foregroundColor(secondaryTextColor)
                    Text("No local lyrics").font(.headline)
                    Text("Embedded lyrics or a matching .lrc file will appear here.").font(.caption).foregroundColor(secondaryTextColor).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }
}

/// Isolated observer so playback clock ticks only update the progress slider and time labels.
private struct PlaybackProgressSection: View {
    @ObservedObject var clock: PlaybackClock
    @Environment(\.colorScheme) private var colorScheme
    var duration: Double
    var seek: (Double) -> Void
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    var body: some View {
        VStack(spacing: -2) {
            CompactPlaybackSlider(value: Binding(get: { isScrubbing ? scrubPosition : clock.position }, set: { scrubPosition = $0 }), maximum: duration, editingChanged: { editing in
                if editing { scrubPosition = clock.position }; isScrubbing = editing
                if !editing { seek(scrubPosition) }
            }).frame(height: 36).accessibilityLabel("Playback position")
            HStack {
                Text(time(isScrubbing ? scrubPosition : clock.position))
                Spacer()
                Text("−" + time(max(0, duration - (isScrubbing ? scrubPosition : clock.position))))
            }.font(.caption.monospacedDigit().weight(.medium))
                .foregroundColor(colorScheme == .dark ? .secondary : Color.primary.opacity(0.72))
        }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// Isolated observer so synced lyrics follow the clock without redrawing Now Playing controls or artwork.
private struct SyncedLyricsContainer: View {
    @ObservedObject var clock: PlaybackClock
    var lines: [LyricLine]
    var seek: (Double) -> Void
    var body: some View {
        SyncedLyricsView(lines: lines, position: clock.position, seek: seek)
    }
}

struct SleepTimerView: View {
    @ObservedObject var clock: PlaybackClock
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                Section {
                    if playback.sleepTimerMode != nil { Text(playback.sleepTimerLabel).font(.headline) }
                    if let remaining = playback.remainingQueueDuration {
                        Text("Queue remaining: " + String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60)).foregroundColor(.secondary)
                    } else { Text("Queue length is unknown. Choose an end-of-song or end-of-queue timer.").foregroundColor(.secondary) }
                }
                Section {
                    Button("End of Song") { playback.setSleepBoundary(.endOfSong); dismiss() }
                    Button("End of Queue") { playback.setSleepBoundary(.endOfQueue); dismiss() }
                } footer: { Text("End of Song stops at the next song ending. End of Queue plays through once, overriding repeat.") }
                if playback.sleepTimerMode != nil {
                    Button("Cancel Sleep Timer", role: .destructive) { playback.cancelSleepTimer(); dismiss() }
                }
                Section {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            if playback.setSleepTimer(seconds: Double(minutes * 60)) { dismiss() }
                        }.disabled(!playback.canSetSleepTimer(seconds: Double(minutes * 60)))
                    }
                } header: { Text("Stop After") } footer: {
                    Text(playback.repeatMode == .off ? "Timers longer than the remaining queue are unavailable. The countdown includes pauses; playback may stop earlier if you shorten the queue." : "Repeat is on, so timed sessions can outlast the queue. The countdown includes pauses.")
                }

            }.navigationTitle("Sleep Timer").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.navigationViewStyle(.stack).tint(.blue)
    }
}
