import AppKit

/// Places the activity board and the bubble next to the pet.
extension PetController {
    /// Stacks the board and the bubble on the free side of the body.
    func placeOverlays(petFrame: CGRect, now: TimeInterval) {
        // Drop the bubble when its time is up
        if let hideTime = bubbleHideTime, now >= hideTime {
            bubbleText = nil
            bubbleHideTime = nil
        }

        // Find where the stack starts and which way it grows
        let growsDown = posture == .underCeiling
        let centerX = petFrame.midX
        var stackEdge: CGFloat
        switch posture {
        case .upright:
            stackEdge = petFrame.minY + footInset + bodyHeight + 4 + carriedIconHeadroom
        case .underCeiling:
            stackEdge = petFrame.minY - 4
        case .onLeftWall, .onRightWall:
            stackEdge = petFrame.maxY + 4
        }
        let limits = screenFrame(near: CGPoint(x: petFrame.midX, y: petFrame.midY))

        // Place the activity board
        if boardRows.isEmpty {
            board.hide()
            isBoardHovered = false
        } else if isBoardPinned {
            placePinnedBoard()
        } else {
            stackEdge = placeFollowingBoard(centerX: centerX, stackEdge: stackEdge, growsDown: growsDown, limits: limits)
        }

        // Place the bubble
        var shownText = bubbleText
        if shownText == nil && motion.isSleeping {
            shownText = "Zzz"
        }
        guard let text = shownText else {
            bubble.hide()
            return
        }
        bubble.show(
            text: text,
            anchor: CGPoint(x: centerX, y: stackEdge),
            growsDown: growsDown,
            limits: limits,
            parent: panel
        )
    }

    /// Keeps the board in the top right corner of the main screen.
    func placePinnedBoard() {
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        let corner = fallbackScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = board.fittingSize(for: boardRows)
        let origin = CGPoint(x: corner.maxX - size.width - 12, y: corner.maxY - size.height - 8)
        board.show(rows: boardRows, frame: CGRect(origin: origin, size: size), parent: nil)
        isBoardHovered = false
    }

    /// Keeps the board next to the body and returns where the bubble goes.
    func placeFollowingBoard(centerX: CGFloat, stackEdge: CGFloat, growsDown: Bool, limits: CGRect) -> CGFloat {
        // Put the board on the free side of the body
        let size = board.fittingSize(for: boardRows)
        var origin = CGPoint(x: centerX - size.width / 2, y: growsDown ? stackEdge - size.height : stackEdge)
        origin.x = min(max(origin.x, limits.minX + 4), limits.maxX - size.width - 4)
        origin.y = min(max(origin.y, limits.minY + 4), limits.maxY - size.height - 2)

        // Snap to half points so the board keeps a steady offset from the pet window
        origin.x = (origin.x * 2).rounded() / 2
        origin.y = (origin.y * 2).rounded() / 2
        let frame = CGRect(origin: origin, size: size)
        board.show(rows: boardRows, frame: frame, parent: panel)

        // Hold the pet still while the cursor is on the board
        isBoardHovered = frame.insetBy(dx: -8, dy: -8).contains(lastMouseLocation)
        return growsDown ? frame.minY - 4 : frame.maxY + 4
    }
}
