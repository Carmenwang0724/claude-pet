import AppKit

/// Draws one line of text inside a rounded pill.
final class BubbleView: NSView {
    var text = ""

    private static let padding = CGSize(width: 10, height: 5)
    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]

    /// Measures the pill needed for a piece of text.
    static func fittingSize(for text: String) -> CGSize {
        let textSize = (text as NSString).size(withAttributes: textAttributes)
        return CGSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw the pill
        let pillRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = pillRect.height / 2
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
        NSColor(white: 1, alpha: 0.96).setFill()
        pill.fill()
        NSColor(white: 0, alpha: 0.18).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        // Draw the text in the middle
        let textSize = (text as NSString).size(withAttributes: BubbleView.textAttributes)
        let textOrigin = CGPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: BubbleView.textAttributes)
    }
}

/// Shows a short message next to the pet.
@MainActor
final class BubblePanel {
    private let panel: PetPanel
    private let bubbleView: BubbleView

    init() {
        // Build a click-through panel
        panel = PetPanel.makeTransparent(size: CGSize(width: 80, height: 24))
        panel.ignoresMouseEvents = true

        // Fill it with the pill view
        bubbleView = BubbleView(frame: CGRect(x: 0, y: 0, width: 80, height: 24))
        panel.contentView = bubbleView
    }

    /// Shows the text centred on an anchor point, above it or below it, kept inside the limits.
    func show(text: String, anchor: CGPoint, growsDown: Bool, limits: CGRect, parent: NSWindow?) {
        // Size and place the pill
        let size = BubbleView.fittingSize(for: text)
        var origin = CGPoint(x: anchor.x - size.width / 2, y: growsDown ? anchor.y - size.height : anchor.y)
        origin.x = min(max(origin.x, limits.minX + 4), limits.maxX - size.width - 4)
        origin.y = min(max(origin.y, limits.minY + 4), limits.maxY - size.height - 2)
        origin.x = (origin.x * 2).rounded() / 2
        origin.y = (origin.y * 2).rounded() / 2
        let frame = CGRect(origin: origin, size: size)

        // Redraw when the text changes
        if bubbleView.text != text {
            bubbleView.text = text
            bubbleView.needsDisplay = true
        }
        let isMisplaced = abs(panel.frame.minX - frame.minX) > 0.25 || abs(panel.frame.minY - frame.minY) > 0.25
        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: true)
        } else if isMisplaced {
            panel.setFrameOrigin(frame.origin)
        }

        // Follow the parent window from now on
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent?.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Hides the pill.
    func hide() {
        guard panel.isVisible else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
