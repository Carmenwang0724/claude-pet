import AppKit
import UniformTypeIdentifiers

/// Draws a file icon with its name underneath, like an icon on the desktop.
final class CarriedIconView: NSView {
    var iconImage: NSImage?
    var title = ""
    var iconSize: CGFloat = 64

    static let labelHeight: CGFloat = 20
    static let labelGap: CGFloat = 2
    static let minimumWidth: CGFloat = 120

    override func draw(_ dirtyRect: NSRect) {
        // Draw the icon at the top
        let iconRect = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: bounds.height - iconSize,
            width: iconSize,
            height: iconSize
        )
        iconImage?.draw(in: iconRect)

        // Set up white text with a soft shadow, cut in the middle when long
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ]

        // Draw the name under the icon
        let labelRect = CGRect(x: 2, y: 0, width: bounds.width - 4, height: CarriedIconView.labelHeight - 2)
        (title as NSString).draw(in: labelRect, withAttributes: attributes)
    }
}

/// Shows a copy of a desktop icon above the other windows while the pet carries it.
@MainActor
final class CarriedIconPanel {
    private let panel: PetPanel
    private let iconSize: CGFloat

    init(fileName: String, iconSize: CGFloat) {
        // Size the panel for the icon and one line of text
        let size = CGSize(
            width: max(iconSize, CarriedIconView.minimumWidth),
            height: iconSize + CarriedIconView.labelGap + CarriedIconView.labelHeight
        )
        self.iconSize = iconSize
        panel = PetPanel.makeTransparent(size: size)
        panel.ignoresMouseEvents = true

        // Fill it with the icon of the file's type and the file name
        let iconView = CarriedIconView(frame: CGRect(origin: .zero, size: size))
        iconView.iconImage = CarriedIconPanel.typeIcon(forFileName: fileName)
        iconView.title = fileName
        iconView.iconSize = iconSize
        panel.contentView = iconView
    }

    /// Picks the icon of a file's type from its name, without touching the file.
    static func typeIcon(forFileName fileName: String) -> NSImage {
        let fileExtension = (fileName as NSString).pathExtension
        var contentType = UTType.folder
        if !fileExtension.isEmpty {
            contentType = UTType(filenameExtension: fileExtension) ?? .data
        }
        return NSWorkspace.shared.icon(for: contentType)
    }

    /// Draws the copy for a file name on a grey background, for checking how it looks.
    static func renderSample(fileName: String, iconSize: CGFloat) -> CGImage? {
        // Build the same view the panel shows
        let size = CGSize(
            width: max(iconSize, CarriedIconView.minimumWidth),
            height: iconSize + CarriedIconView.labelGap + CarriedIconView.labelHeight
        )
        let iconView = CarriedIconView(frame: CGRect(origin: .zero, size: size))
        iconView.iconImage = typeIcon(forFileName: fileName)
        iconView.title = fileName
        iconView.iconSize = iconSize

        // Draw it over grey at twice the size
        let image = NSImage(size: size, flipped: false) { drawingRect in
            NSColor(white: 0.45, alpha: 1).setFill()
            drawingRect.fill()
            iconView.draw(drawingRect)
            return true
        }
        var proposedRect = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    /// Puts the middle of the icon picture on a screen point.
    func show(iconCenter: CGPoint, parent: NSWindow?) {
        // Work out where the panel goes
        let size = panel.frame.size
        var origin = CGPoint(
            x: iconCenter.x - size.width / 2,
            y: iconCenter.y + iconSize / 2 - size.height
        )
        origin.x = (origin.x * 2).rounded() / 2
        origin.y = (origin.y * 2).rounded() / 2

        // Move it when it is off by more than a hair
        let isMisplaced = abs(panel.frame.minX - origin.x) > 0.25 || abs(panel.frame.minY - origin.y) > 0.25
        if isMisplaced {
            panel.setFrameOrigin(origin)
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

    /// Hides the copy.
    func hide() {
        guard panel.isVisible else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
