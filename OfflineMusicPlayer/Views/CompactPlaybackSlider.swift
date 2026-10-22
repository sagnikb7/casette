import SwiftUI
import UIKit

/// A clearly visible thumb with the same generous 44-point scrubbing surface.
struct CompactPlaybackSlider: UIViewRepresentable {
    @Binding var value: Double
    var maximum: Double
    var editingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> ScrubbingSlider {
        let slider = ScrubbingSlider()
        slider.setThumbImage(Self.thumb, for: .normal)
        slider.setThumbImage(Self.thumb, for: .highlighted)
        slider.minimumTrackTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.88)
                : UIColor.black.withAlphaComponent(0.75)
        }
        slider.maximumTrackTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.22)
                : UIColor.black.withAlphaComponent(0.18)
        }
        slider.accessibilityLabel = "Playback position"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.started), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.finished), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: ScrubbingSlider, context: Context) {
        context.coordinator.parent = self
        slider.maximumValue = Float(max(0.01, maximum.isFinite ? maximum : 0.01))
        if !slider.isTracking { slider.value = Float(value.isFinite ? value : 0) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    private static let thumb: UIImage = {
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { ctx in
            let rect = CGRect(x: 2, y: 2, width: 20, height: 20)
            ctx.cgContext.saveGState()
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.28).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: rect).fill()
            ctx.cgContext.restoreGState()
        }
    }()
    final class Coordinator: NSObject {
        var parent: CompactPlaybackSlider
        private var editing = false
        init(_ parent: CompactPlaybackSlider) { self.parent = parent }
        @objc func changed(_ slider: UISlider) {
            parent.value = Double(slider.value)
            // VoiceOver changes the value without a touch tracking session.
            if !editing { parent.editingChanged(false) }
        }
        @objc func started() { guard !editing else { return }; editing = true; parent.editingChanged(true) }
        @objc func finished() { editing = false; parent.editingChanged(false) }
    }
}

final class ScrubbingSlider: UISlider {
    private var dragOffset: CGFloat = 0
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        let thumb = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
        // Keep a 44-point thumb hit region, even though the visible thumb is 24 points.
        dragOffset = abs(point.x - thumb.midX) <= 22 ? point.x - thumb.midX : 0
        sendActions(for: .touchDown)
        updateValue(at: point)
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateValue(at: touch.location(in: self)); return true
    }
    private func updateValue(at point: CGPoint) {
        let track = trackRect(forBounds: bounds)
        let left = thumbRect(forBounds: bounds, trackRect: track, value: minimumValue).midX
        let right = thumbRect(forBounds: bounds, trackRect: track, value: maximumValue).midX
        guard right > left else { return }
        let fraction = max(0, min(1, (point.x - dragOffset - left) / (right - left)))
        value = minimumValue + Float(fraction) * (maximumValue - minimumValue)
        sendActions(for: .valueChanged)
    }
}
