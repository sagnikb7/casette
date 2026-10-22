import SwiftUI

struct LyricsEdgeFadeMask: View {
    var edgeHeight: CGFloat = 36
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.08),
                    .init(color: .black.opacity(0.45), location: 0.5),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: edgeHeight)
            Rectangle()
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.5),
                    .init(color: .clear, location: 0.92),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: edgeHeight)
        }
    }
}

extension View {
    /// Softens the top and bottom edges of the lyrics container so scrolling lines blend smoothly instead of clipping abruptly.
    func lyricsEdgeFade(height: CGFloat = 36) -> some View {
        mask { LyricsEdgeFadeMask(edgeHeight: height) }
    }
}

struct SyncedLyricsView: View {
    var lines: [LyricLine]
    var position: Double
    var seek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var current: Int? { LRCParser.activeLine(in: lines, at: position) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Button { seek(line.time) } label: {
                            Text(line.text.isEmpty ? "♪" : line.text).font(.body.weight(.semibold))
                                .foregroundColor(.primary).opacity(line.id == current ? 1 : 0.45)
                                .padding(.vertical, 3).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(VisualPressButtonStyle()).id(line.id)
                    }
                }
                .padding(.vertical, 20)
                .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84, blendDuration: 0.1), value: current)
            }
            .lyricsEdgeFade()
            .task(id: current) {
                // Wait for this lazy row's scroll anchor to be laid out before following it.
                await Task.yield()
                if !Task.isCancelled { follow(proxy) }
            }
            .onChange(of: lines) { _ in follow(proxy) }
        }
    }
    private func follow(_ proxy: ScrollViewProxy) {
        guard let current = current else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84, blendDuration: 0.1)) { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.3)) }
    }
}
