import SwiftUI
import UIKit

/// Short, event-driven feedback; the layout and the button's content shape stay fixed.
struct VisualPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.75, blendDuration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    /// Quieter row dividers for every list.
    func subtleSeparator() -> some View { listRowSeparatorTint(Color.primary.opacity(0.08)) }
    /// Keeps the last row of a pushed list clear of the floating mini player.
    func miniPlayerClearance() -> some View { modifier(MiniPlayerClearance()) }
}

private struct MiniPlayerClearance: ViewModifier {
    @EnvironmentObject private var playback: PlaybackCoordinator
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        content.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: playback.currentTrack == nil ? 0 : 56) }
        #endif
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Single-line text that never truncates: it scrolls when too wide, with faded edges.
struct MarqueeText: View {
    var text: String
    var font: Font
    var color: Color = .primary
    /// When true the view is only as wide as its text (up to the space offered), so siblings sit right after it.
    var hugging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    private let gap: CGFloat = 40
    private var overflows: Bool { containerWidth > 0 && textWidth > containerWidth + 0.5 }

    var body: some View {
        Text(hugging ? text : " ").font(font).lineLimit(1).opacity(0)
            .frame(maxWidth: hugging ? nil : .infinity, alignment: .leading)
            .background(GeometryReader { Color.clear.preference(key: MarqueeWidthKey.self, value: [0: $0.size.width]) })
            .background(Text(text).font(font).fixedSize().hidden()
                .background(GeometryReader { Color.clear.preference(key: MarqueeWidthKey.self, value: [1: $0.size.width]) }))
            .onPreferenceChange(MarqueeWidthKey.self) { values in
                containerWidth = values[0] ?? containerWidth
                textWidth = values[1] ?? textWidth
            }
            .overlay(alignment: .leading) {
                content
            }
            .clipped()
            .mask {
                if overflows {
                    fade
                } else {
                    Color.black
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }

    @ViewBuilder private var content: some View {
        if !overflows {
            Text(text).font(font).foregroundColor(color).lineLimit(1)
        } else if reduceMotion {
            ScrollView(.horizontal, showsIndicators: false) { Text(text).font(font).foregroundColor(color).fixedSize().padding(.horizontal, 12) }
        } else {
            MarqueeScroller(text: text, font: font, color: color, distance: textWidth + gap, gap: gap)
                .id(text + "\(Int(textWidth))")
        }
    }
    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
        }
    }
}

private struct MarqueeScroller: View {
    var text: String
    var font: Font
    var color: Color
    var distance: CGFloat
    var gap: CGFloat
    @State private var moving = false
    var body: some View {
        HStack(spacing: gap) {
            Text(text).font(font).foregroundColor(color)
            Text(text).font(font).foregroundColor(color)
        }.fixedSize().offset(x: moving ? -distance : 0)
            .onAppear {
                withAnimation(.linear(duration: Double(distance) / 35).delay(1.5).repeatForever(autoreverses: false)) { moving = true }
            }
    }
}

/// Animate a transform of the existing thumbnail, never its layout or blur.
struct PlaybackArtworkView: View {
    var reduceMotion: Bool
    var track: Track?
    var side: CGFloat
    var isPlaying: Bool
    var cornerRadius: CGFloat = 6
    static let playingScale: CGFloat = 0.92
    static let pausedScale: CGFloat = playingScale * 0.8
    var scale: CGFloat {
        track == nil ? 1 : (reduceMotion ? 1 : (isPlaying ? Self.playingScale : Self.pausedScale))
    }
    var springAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return isPlaying
            ? .spring(response: 0.42, dampingFraction: 0.56, blendDuration: 0.1)
            : .spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.1)
    }
    var body: some View {
        ArtworkView(track: track, cornerRadius: cornerRadius, edgeInsetCrop: 2).frame(width: side, height: side)
            .shadow(
                color: .black.opacity(track == nil ? 0 : (isPlaying || reduceMotion) ? 0.28 : 0.12),
                radius: (isPlaying || reduceMotion) ? 10 : 5,
                x: 0,
                y: (isPlaying || reduceMotion) ? 6 : 3
            )
            .scaleEffect(scale)
            .animation(springAnimation, value: isPlaying)
            .frame(width: side, height: side)
    }
}


/// Native gesture arbitration prevents a released hold from also skipping a song.
struct SeekTransportButton: UIViewRepresentable {
    var symbol: String
    var label: String
    var pointSize: CGFloat = 24
    var tap: () -> Void
    var seek: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize)), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.accessibilityHint = "Touch and hold to seek"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.4
        button.addGestureRecognizer(hold)
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: symbol == "forward.fill" ? "Seek forward" : "Seek backward", target: context.coordinator, selector: #selector(Coordinator.accessibleSeek))]
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject {
        var parent: SeekTransportButton
        private var timer: Timer?
        init(_ parent: SeekTransportButton) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(stop), name: UIApplication.willResignActiveNotification, object: nil)
        }
        @objc func tapped() { parent.tap() }
        @objc func accessibleSeek() -> Bool { parent.seek(); return true }
        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began {
                beginSeeking()
            } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                stop()
            }
        }
        func beginSeeking() {
            stop()
            parent.seek()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.parent.seek() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        @objc func stop() { timer?.invalidate(); timer = nil }
        deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    }
}
