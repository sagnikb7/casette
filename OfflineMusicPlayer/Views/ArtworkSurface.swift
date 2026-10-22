import SwiftUI
import CoreImage
import ImageIO

/// Tiny, static backgrounds generated once per artwork, never blurred per playback tick.
actor ArtworkSurfaceCache {
    static let shared = ArtworkSurfaceCache()
    private let cache = NSCache<NSString, UIImage>()
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    init() { cache.countLimit = 16; cache.totalCostLimit = 16 * 64 * 64 * 4 }

    func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let input = CIImage(cgImage: thumbnail)
        let extent = input.extent
        let rotated = input.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: extent.width, ty: extent.height))
        // Boost saturation and subtle contrast before blurring so the ambient canvas retains rich album-art colors.
        let vibrant = rotated.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.85,
            kCIInputContrastKey: 1.08
        ])
        let blurred = vibrant.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14]).cropped(to: extent)
        guard let output = context.createCGImage(blurred, from: extent) else { return nil }
        let result = UIImage(cgImage: output)
        cache.setObject(result, forKey: key, cost: output.width * output.height * 4)
        return result
    }
}

struct ArtworkSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var artworkURL: URL?
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(UIColor.systemBackground)
                if !reduceTransparency, let image = image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .saturation(scheme == .dark ? 1.45 : 1.15)
                        .brightness(scheme == .dark ? -0.06 : 0.14)
                        .clipped()
                        .transition(.opacity)
                    LinearGradient(
                        colors: scheme == .dark
                            ? [
                                Color.black.opacity(0.18),
                                Color.black.opacity(0.28),
                                Color.black.opacity(0.46)
                            ]
                            : [
                                Color.white.opacity(0.54),
                                Color.white.opacity(0.64),
                                Color.white.opacity(0.76)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }.animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: artworkURL)
        }.ignoresSafeArea().accessibilityHidden(true)
            .task(id: artworkURL) {
                guard !reduceTransparency, let url = artworkURL else {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { image = nil }
                    return
                }
                let rendered = await ArtworkSurfaceCache.shared.image(at: url)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { image = rendered }
            }
    }
}
