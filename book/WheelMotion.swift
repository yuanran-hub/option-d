import AppKit
import QuartzCore
import SwiftUI

// Drive only keyboard/click scrolling. The trackpad keeps its native momentum.
@MainActor final class WheelMotion: NSObject, ObservableObject {
    weak var scrollView: NSScrollView?
    private var frames: CADisplayLink?
    private var target: CGFloat = 0
    private var position: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTick: CFTimeInterval = 0

    func move(to y: CGFloat) -> Bool {
        guard let scrollView, scrollView.window != nil else { return false }
        target = y
        if frames != nil { return true }

        position = scrollView.contentView.bounds.minY
        velocity = 0
        lastTick = CACurrentMediaTime()
        let link = scrollView.displayLink(target: self, selector: #selector(advance(_:)))
        let rate = Float(scrollView.window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        frames = link
        link.add(to: .main, forMode: .common)
        return true
    }

    func stop() {
        frames?.invalidate()
        frames = nil
    }

    @objc private func advance(_ frame: CADisplayLink) {
        guard let scrollView, scrollView.window != nil else { stop(); return }
        let now = frame.targetTimestamp
        let dt = max(0, now - lastTick)
        lastTick = now
        // Exact critically damped spring step. A new target retains position and velocity.
        let rate = 27.0
        let offset = position - target
        let slope = velocity + rate * offset
        let decay = exp(-rate * dt)
        position = target + (offset + slope * dt) * decay
        velocity = (velocity - rate * slope * dt) * decay
        if abs(position - target) < 0.12 && abs(velocity) < 4 {
            position = target
            stop()
        }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: position))
        scrollView.reflectScrolledClipView(clip)
    }
}

// Placed inside the scroll document so the motion uses the actual viewport on this display.
struct WheelScrollAttachment: NSViewRepresentable {
    let motion: WheelMotion

    final class Attachment: NSView {
        weak var motion: WheelMotion?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            motion?.scrollView = enclosingScrollView
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Attachment { Attachment() }
    func updateNSView(_ view: Attachment, context: Context) {
        view.motion = motion
        motion.scrollView = view.enclosingScrollView
    }
}
