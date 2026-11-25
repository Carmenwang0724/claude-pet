import AppKit

/// Describes one line of the activity board.
struct BoardRow: Equatable {
    let status: ActivityStatus?
    let title: String
    let timeText: String
}

/// Describes the short line shown while the board is collapsed.
struct BoardBadge: Equatable {
    let status: ActivityStatus?
    let text: String
}

/// Holds the widths of the three text columns of the board.
private struct BoardColumns {
    let statusWidth: CGFloat
    let titleWidth: CGFloat
    let timeWidth: CGFloat
}

/// Draws one row per session and reports which row was clicked.
final class ActivityBoardView: NSView {
    var rows: [BoardRow] = []
    var badge = BoardBadge(status: nil, text: "")
    var isCollapsed = false
    var onSelect: ((Int) -> Void)?
    var onToggle: (() -> Void)?

    static let headerTitle = "Claude"
    private static let rowHeight: CGFloat = 22
    private static let headerHeight: CGFloat = 18
    private static let badgeHeight: CGFloat = 24
    private static let collapseMarkWidth: CGFloat = 10
    private static let headerAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor(white: 0.5, alpha: 1),
    ]
    private static let sidePadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 6
    private static let dotDiameter: CGFloat = 8
    private static let columnGap: CGFloat = 8
    private static let statusAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(white: 0.18, alpha: 1),
    ]
    private static let timeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(white: 0.45, alpha: 1),
    ]

    override var isFlipped: Bool {
        return true
    }

    /// Names a status the way the board shows it.
    static func statusText(for status: ActivityStatus?) -> String {
        guard let status = status else {
            return ""
        }
        switch status {
        case .needsPermission:
            return "Needs approval"
        case .needsAnswer:
            return "Needs input"
        case .blocked:
            return "Blocked"
        case .ready:
            return "Ready"
        case .running:
            return "Running"
        }
    }

    /// Picks the dot colour of a status.
    static func color(for status: ActivityStatus?) -> NSColor {
        guard let status = status else {
            return NSColor(white: 0.6, alpha: 1)
        }
        switch status {
        case .needsPermission, .needsAnswer:
            return NSColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1)
        case .blocked:
            return NSColor(red: 0.86, green: 0.22, blue: 0.20, alpha: 1)
        case .ready:
            return NSColor(red: 0.16, green: 0.65, blue: 0.33, alpha: 1)
        case .running:
            return NSColor(red: 0.20, green: 0.47, blue: 0.90, alpha: 1)
        }
    }

    /// Measures the badge shown while the board is collapsed.
    static func fittingSize(for badge: BoardBadge) -> CGSize {
        let textSize = (badge.text as NSString).size(withAttributes: statusAttributes)
        let width = sidePadding * 2 + dotDiameter + columnGap + ceil(textSize.width)
        return CGSize(width: ceil(width), height: badgeHeight)
    }

    /// Measures the open board needed for a list of rows.
    static func fittingSize(for rows: [BoardRow]) -> CGSize {
        let columns = measureColumns(rows: rows)
        var width = sidePadding * 2 + dotDiameter + columnGap + columns.statusWidth + columnGap + columns.titleWidth
        if columns.timeWidth > 0 {
            width += columnGap + columns.timeWidth
        }
        let height = verticalPadding * 2 + headerHeight + rowHeight * CGFloat(rows.count)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    /// Finds the widest text of each column.
    private static func measureColumns(rows: [BoardRow]) -> BoardColumns {
        var statusWidth: CGFloat = 0
        var titleWidth: CGFloat = 0
        var timeWidth: CGFloat = 0
        for row in rows {
            let statusSize = (statusText(for: row.status) as NSString).size(withAttributes: statusAttributes)
            let titleSize = (row.title as NSString).size(withAttributes: titleAttributes)
            let timeSize = (row.timeText as NSString).size(withAttributes: timeAttributes)
            statusWidth = max(statusWidth, ceil(statusSize.width))
            titleWidth = max(titleWidth, ceil(titleSize.width))
            timeWidth = max(timeWidth, ceil(timeSize.width))
        }
        return BoardColumns(statusWidth: statusWidth, titleWidth: titleWidth, timeWidth: timeWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCollapsed {
            drawBadge()
        } else {
            drawOpenBoard()
        }
    }

    /// Draws the pill with the most urgent colour and the count of unread sessions.
    private func drawBadge() {
        // Draw the pill
        let pillRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = pillRect.height / 2
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
        NSColor(white: 1, alpha: 0.97).setFill()
        pill.fill()
        NSColor(white: 0, alpha: 0.18).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        // Draw the dot and the text
        let middle = bounds.height / 2
        let dotDiameter = ActivityBoardView.dotDiameter
        let dotRect = CGRect(
            x: ActivityBoardView.sidePadding,
            y: middle - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        ActivityBoardView.color(for: badge.status).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        let text = badge.text as NSString
        let textSize = text.size(withAttributes: ActivityBoardView.statusAttributes)
        text.draw(
            at: CGPoint(x: dotRect.maxX + ActivityBoardView.columnGap, y: middle - textSize.height / 2),
            withAttributes: ActivityBoardView.statusAttributes
        )
    }

    /// Draws the card with a header that collapses it and one row per session.
    private func drawOpenBoard() {
        // Draw the card
        let cardRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)
        NSColor(white: 1, alpha: 0.97).setFill()
        card.fill()
        NSColor(white: 0, alpha: 0.18).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Draw the header with the collapse mark on the right
        let headerTop = ActivityBoardView.verticalPadding
        let headerMiddle = headerTop + ActivityBoardView.headerHeight / 2
        let headerText = ActivityBoardView.headerTitle as NSString
        let headerSize = headerText.size(withAttributes: ActivityBoardView.headerAttributes)
        headerText.draw(
            at: CGPoint(x: ActivityBoardView.sidePadding, y: headerMiddle - headerSize.height / 2),
            withAttributes: ActivityBoardView.headerAttributes
        )
        let markRight = bounds.width - ActivityBoardView.sidePadding
        let mark = NSBezierPath()
        mark.move(to: CGPoint(x: markRight - ActivityBoardView.collapseMarkWidth, y: headerMiddle))
        mark.line(to: CGPoint(x: markRight, y: headerMiddle))
        mark.lineWidth = 2
        mark.lineCapStyle = .round
        NSColor(white: 0.5, alpha: 1).setStroke()
        mark.stroke()

        // Draw each row
        let columns = ActivityBoardView.measureColumns(rows: rows)
        for index in 0..<rows.count {
            drawRow(rows[index], index: index, columns: columns)
        }
    }

    /// Draws the dot, status, title and time of one row.
    private func drawRow(_ row: BoardRow, index: Int, columns: BoardColumns) {
        let rowTop = ActivityBoardView.verticalPadding + ActivityBoardView.headerHeight
            + ActivityBoardView.rowHeight * CGFloat(index)
        let rowMiddle = rowTop + ActivityBoardView.rowHeight / 2

        // Draw the status dot
        let dotDiameter = ActivityBoardView.dotDiameter
        let dotRect = CGRect(
            x: ActivityBoardView.sidePadding,
            y: rowMiddle - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        ActivityBoardView.color(for: row.status).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // Draw the status
        var textX = dotRect.maxX + ActivityBoardView.columnGap
        let statusText = ActivityBoardView.statusText(for: row.status) as NSString
        let statusSize = statusText.size(withAttributes: ActivityBoardView.statusAttributes)
        statusText.draw(
            at: CGPoint(x: textX, y: rowMiddle - statusSize.height / 2),
            withAttributes: ActivityBoardView.statusAttributes
        )
        textX += columns.statusWidth + ActivityBoardView.columnGap

        // Draw the title
        let titleText = row.title as NSString
        let titleSize = titleText.size(withAttributes: ActivityBoardView.titleAttributes)
        titleText.draw(
            at: CGPoint(x: textX, y: rowMiddle - titleSize.height / 2),
            withAttributes: ActivityBoardView.titleAttributes
        )

        // Draw the time against the right edge
        let timeText = row.timeText as NSString
        let timeSize = timeText.size(withAttributes: ActivityBoardView.timeAttributes)
        let timeX = bounds.width - ActivityBoardView.sidePadding - timeSize.width
        timeText.draw(
            at: CGPoint(x: timeX, y: rowMiddle - timeSize.height / 2),
            withAttributes: ActivityBoardView.timeAttributes
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseUp(with event: NSEvent) {
        // Open or collapse the board from the badge or the header
        let location = convert(event.locationInWindow, from: nil)
        let headerBottom = ActivityBoardView.verticalPadding + ActivityBoardView.headerHeight
        if isCollapsed || location.y < headerBottom {
            onToggle?()
            return
        }

        // Work out which row the click landed on
        let offset = location.y - headerBottom
        let index = Int(offset / ActivityBoardView.rowHeight)
        guard index < rows.count else {
            return
        }
        onSelect?(index)
    }

    /// Draws the board into a bitmap on a grey background.
    func renderSnapshot(scale: CGFloat) -> CGImage? {
        let pixelWidth = Int(bounds.width * scale)
        let pixelHeight = Int(bounds.height * scale)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: bitmap)
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let bitmapContext = context, let image = bitmap.cgImage else {
            return nil
        }
        bitmapContext.setFillColor(CGColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        bitmapContext.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return bitmapContext.makeImage()
    }
}

/// Shows the activity board in its own floating panel.
@MainActor
final class ActivityBoard {
    private let panel: PetPanel
    private let boardView: ActivityBoardView
    private var measuredRows: [BoardRow] = []
    private var measuredSize = CGSize.zero

    init() {
        // Build a panel that takes clicks
        panel = PetPanel.makeTransparent(size: CGSize(width: 120, height: 34))
        boardView = ActivityBoardView(frame: CGRect(x: 0, y: 0, width: 120, height: 34))
        panel.contentView = boardView
    }

    /// Gives where the board is on screen, or an empty frame while it is hidden.
    var visibleFrame: CGRect {
        return panel.isVisible ? panel.frame : .zero
    }

    /// Sets the handler called with the index of a clicked row.
    func setSelectionHandler(_ handler: @escaping (Int) -> Void) {
        boardView.onSelect = handler
    }

    /// Sets the handler called when the badge or the header is clicked.
    func setToggleHandler(_ handler: @escaping () -> Void) {
        boardView.onToggle = handler
    }

    /// Shows the rows, or the badge when collapsed, at the given place, riding along with a parent window.
    func show(rows: [BoardRow], badge: BoardBadge, isCollapsed: Bool, frame: CGRect, parent: NSWindow?) {
        // Redraw when anything shown changes
        if boardView.rows != rows || boardView.badge != badge || boardView.isCollapsed != isCollapsed {
            boardView.rows = rows
            boardView.badge = badge
            boardView.isCollapsed = isCollapsed
            boardView.needsDisplay = true
        }

        // Resize or move only when needed
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

    /// Measures the board for a list of rows, reusing the last answer when the rows are the same.
    func fittingSize(for rows: [BoardRow]) -> CGSize {
        if rows != measuredRows {
            measuredRows = rows
            measuredSize = ActivityBoardView.fittingSize(for: rows)
        }
        return measuredSize
    }

    /// Measures the badge shown while the board is collapsed.
    func fittingSize(for badge: BoardBadge) -> CGSize {
        return ActivityBoardView.fittingSize(for: badge)
    }

    /// Hides the board.
    func hide() {
        guard panel.isVisible else {
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Draws the board into a bitmap for checking.
    func renderSnapshot(scale: CGFloat) -> CGImage? {
        return boardView.renderSnapshot(scale: scale)
    }
}
