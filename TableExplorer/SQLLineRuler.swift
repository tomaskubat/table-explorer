import AppKit

final class SQLLineRuler: NSRulerView {
    private var starts = [0]

    func setText(_ text: String) {
        let source = text as NSString
        starts = [0]
        var start = 0
        while start < source.length {
            var end = 0, contentEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: start, length: 0))
            if end > contentEnd { starts.append(end) }
            start = end
        }
        ruleThickness = max(31, CGFloat(String(starts.count).count) * 8 + 13)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor = clientView as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let first = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
        var low = 0, high = starts.count
        while low < high {
            let mid = low + (high - low) / 2
            if starts[mid] <= first { low = mid + 1 } else { high = mid }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: max(9, (editor.font?.pointSize ?? 13) - 2), weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let length = (editor.string as NSString).length
        for index in max(0, low - 1)..<starts.count {
            let position = starts[index]
            let line = position == length ? layout.extraLineFragmentRect :
                layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
            let top = convert(NSPoint(x: 0, y: line.minY + editor.textContainerOrigin.y), from: editor).y
            if top > rect.maxY { break }
            let number = String(index + 1) as NSString
            number.draw(at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 5, y: top), withAttributes: attributes)
        }
    }
}
