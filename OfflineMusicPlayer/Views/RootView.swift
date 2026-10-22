import SwiftUI

struct PickerRequest: Identifiable {
    let id = UUID()
    var folders: Bool
    var reconnecting: UUID? = nil
    var excludeFrom: UUID? = nil
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var playerAnimation
    @State private var selectedTab = 0
    @State private var showingPlayer = false
    @State private var playerDragOffset: CGFloat = 0
    @State private var launched = false
    @State private var keyboardVisible = false
    @AppStorage("appearance") private var appearance = "system"
    static let playerSpring = Animation.spring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.1)
    private func setPlayerShowing(_ visible: Bool) {
        if reduceMotion {
            playerDragOffset = 0
            showingPlayer = visible
        } else {
            withAnimation(Self.playerSpring) {
                playerDragOffset = 0
                showingPlayer = visible
            }
        }
    }
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            content
            if showingPlayer {
                NowPlayingView(
                    animationNamespace: playerAnimation,
                    dismissDragOffset: $playerDragOffset,
                    onDismiss: { setPlayerShowing(false) }
                )
                    .environmentObject(library)
                    .environmentObject(playback)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity, removal: .opacity))
                    .zIndex(10)
            }
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .sheet(item: $library.pickerRequest) { request in
                MusicPicker(folders: request.folders, selected: { urls in
                    if request.folders { if let url = urls.first {
                        if let source = request.excludeFrom { library.excludeFolder(url, from: source) }
                        else { library.addFolder(url, reconnecting: request.reconnecting) }
                    } }
                    else { library.importFiles(urls) }
                    library.pickerRequest = nil
                }, cancelled: { library.pickerRequest = nil })
            }
            .alert("Cassette", isPresented: Binding(get: { library.errorMessage != nil || playback.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil; playback.errorMessage = nil } })) {
                Button("OK", role: .cancel) { library.errorMessage = nil; playback.errorMessage = nil }
            } message: { Text(playback.errorMessage ?? library.errorMessage ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                // Keyboard-safe-area avoidance moves the overlay; only the hidden tab-bar offset must go.
                keyboardVisible = frame.minY < UIScreen.main.bounds.maxY && frame.height > 0
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            .onOpenURL { url in
                if CassetteWidgetConfiguration.opensPlayer(url) {
                    playback.connect(library)
                    if playback.currentTrack != nil {
                        setPlayerShowing(true)
                    } else {
                        setPlayerShowing(false); selectedTab = 0
                    }
                } else if CassetteWidgetConfiguration.opensLibrary(url) {
                    setPlayerShowing(false); selectedTab = 0
                }
            }
            .onAppear {
                if !launched { launched = true; playback.connect(library); library.setPlaybackActive(playback.playbackRequested || playback.isPlaying); library.discoverChangesOnLaunch() }
            }
            .onChange(of: playback.playbackRequested) { library.setPlaybackActive($0 || playback.isPlaying) }
            .onChange(of: playback.isPlaying) { library.setPlaybackActive($0 || playback.playbackRequested) }
            .onChange(of: scenePhase) { phase in
                if phase == .active { library.setSceneActive(true); playback.checkSleepTimer(); playback.refreshWidgets() }
                else if phase == .background { library.setSceneActive(false); playback.persist(); playback.refreshWidgets() }
            }
    }
    @ViewBuilder private var content: some View {
        #if targetEnvironment(macCatalyst)
        tabs.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
        #else
        tabs.overlay(alignment: .bottom) { miniPlayer.padding(.bottom, keyboardVisible ? 0 : 49) }
        #endif
    }
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            navigation { LibraryHomeView() }.tabItem { Label("Library", systemImage: "music.note") }.tag(0)
            navigation { PlaylistsView() }.tabItem { Label("Playlists", systemImage: "music.note.list") }.tag(1)
            navigation { SearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(2)
            navigation { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }.accentColor(.blue)
    }
    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Each list/scroll view applies miniPlayerClearance() itself; a NavigationView-level inset doesn't reach pushed screens.
        NavigationView { content().background(BackGestureSupport()) }.navigationViewStyle(.stack)
    }
    @ViewBuilder private var miniPlayer: some View {
        if playback.currentTrack != nil {
            MiniPlayer(
                showingPlayer: Binding(get: { showingPlayer }, set: { setPlayerShowing($0) }),
                animationNamespace: playerAnimation
            )
        }
    }
}

struct LibraryHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        Group {
            if library.visibleTracks.isEmpty {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "music.note").font(.system(size: 56)).foregroundColor(.blue).padding(.top, 36)
                        Text("Your music. Your pocket.").font(.title2.bold()).multilineTextAlignment(.center)
                        Text("Add a folder from On My iPod, or import audio files. Cassette finds the songs inside and keeps them ready offline.")
                            .foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button { library.pickerRequest = PickerRequest(folders: true) } label: { Label("Add Music Folder", systemImage: "folder.badge.plus").frame(minHeight: 44) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("addMusicFolder")
                        Button("Import Audio Files") { library.pickerRequest = PickerRequest(folders: false) }.frame(minHeight: 44)
                        Label("Your music stays on your device.", systemImage: "checkmark.shield").font(.footnote).foregroundColor(.secondary)
                        if library.scanning { ScanProgressView() }
                    }.padding(24)
                }
            } else {
                List {
                    Group {
                    NavigationLink { SongListView(title: "Songs", tracks: library.sortedTracks) } label: { libraryCategory("Songs", symbol: "music.note", count: library.visibleTracks.count) }
                    NavigationLink { AlbumsView() } label: { libraryCategory("Albums", symbol: "square.stack", count: library.browse.albums.count) }
                    NavigationLink { GroupsView(kind: .artist) } label: { libraryCategory("Artists", symbol: "music.mic", count: library.browse.artistNames.count) }
                    NavigationLink { GroupsView(kind: .genre) } label: { libraryCategory("Genres", symbol: "waveform", count: library.browse.genreNames.count) }
                    NavigationLink { FoldersView() } label: { libraryCategory("Folders", symbol: "folder", count: library.sources.count) }
                    NavigationLink { ListeningHistoryView() } label: { libraryCategory("Recently Played", symbol: "clock", count: library.historySongs.count) }
                    }.subtleSeparator()
                    Section {
                        if library.recentlyPlayed.isEmpty {
                            Text("Songs you play will appear here.").font(.subheadline).foregroundColor(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(library.recentlyPlayed) { song in
                                        RecentlyPlayedTile(track: song.track).frame(width: 112)
                                    }
                                }.padding(.vertical, 6)
                            }
                        }
                    } header: {
                        NavigationLink { ListeningHistoryView() } label: {
                            HStack {
                                Text("Recently Played")
                                Spacer()
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundColor(.primary)
                            .accessibilityLabel("Recently Played, show full listening history")
                    }.textCase(nil)
                    if library.scanning { ScanProgressView() }
                }.listStyle(.plain).miniPlayerClearance()
            }
        }.navigationTitle("Library")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Menu {
                Button("Add Music Folder") { library.pickerRequest = PickerRequest(folders: true) }
                Button("Import Audio Files") { library.pickerRequest = PickerRequest(folders: false) }
                Button("Rescan Library") { library.rescan() }
            } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add music") } }
    }
    private func libraryCategory(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 8)
            Text("\(count)").foregroundColor(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
    }
}

struct ScanProgressView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        HStack {
            ProgressView()
            VStack(alignment: .leading) {
                Text(library.scanStatus).font(.subheadline)
                Text("\(library.scannedCount) audio files checked").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Cancel") { library.cancelScan() }
        }.padding(.vertical, 8)
    }
}

struct EmptyLibraryView: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundColor(.blue).accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(detail).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
