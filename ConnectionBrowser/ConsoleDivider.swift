import AppKit
import SwiftUI

/// AppKit supplies the resize cursor and continuous dragging even outside the grip.
struct ConsoleDivider: NSViewRepresentable {
    let height: CGFloat
    let limits: ClosedRange<CGFloat>
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) {
        view.height = height; view.limits = limits; view.resize = resize
        view.setAccessibilityValue(NSNumber(value: Double(height)))
    }

    final class Grip: NSView {
        var height: CGFloat = 135
        var limits: ClosedRange<CGFloat> = 66...600
        var resize: ((CGFloat) -> Void)?
        private var start: (y: CGFloat, height: CGFloat)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.splitter)
            setAccessibilityLabel("SQL console height"); setAccessibilityOrientation(.horizontal)
        }
        required init?(coder: NSCoder) { nil }
        override func resetCursorRects() {
            super.resetCursorRects(); addCursorRect(bounds, cursor: .resizeUpDown)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 9, y: bounds.midY - 1, width: 18, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
        override func mouseDown(with event: NSEvent) { start = (event.locationInWindow.y, height) }
        override func mouseDragged(with event: NSEvent) {
            if let start { adjust(start.height + event.locationInWindow.y - start.y) }
        }
        override func mouseUp(with event: NSEvent) { start = nil }
        @discardableResult private func adjust(_ proposed: CGFloat) -> Bool {
            let next = min(max(proposed, limits.lowerBound), limits.upperBound)
            guard next != height else { return false }
            resize?(next); return true
        }
        override func accessibilityPerformIncrement() -> Bool { adjust(height + 20) }
        override func accessibilityPerformDecrement() -> Bool { adjust(height - 20) }
    }
}
