import AppKit

/// Receives the mouse gestures made on the pet.
@MainActor
protocol PetViewDelegate: AnyObject {
    func petViewDidBeginDrag(at location: CGPoint)
    func petViewDidDrag(to location: CGPoint)
    func petViewDidEndDrag(velocity: CGVector)
    func petViewWasClicked()
    func petViewDidReceiveFiles(_ fileURLs: [URL])
    func petViewMenu() -> NSMenu
}

/// Floats above other windows without taking keyboard focus.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }

    /// Builds a transparent borderless panel of the given size.
    static func makeTransparent(size: CGSize) -> PetPanel {
        let panel = PetPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// Lets the panel sit anywhere, including partly off screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// Records where the mouse was at one moment of a drag.
private struct DragSample {
    let time: TimeInterval
    let location: CGPoint
}

/// Draws the current frame and reports mouse gestures and dropped files.
final class PetView: NSView {
    weak var delegate: PetViewDelegate?
    private let spriteLayer = CALayer()
    private var pressLocation: CGPoint?
    private var isDragging = false
    private var dragSamples: [DragSample] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Host a layer that holds the turnable drawing
        let hostLayer = CALayer()
        layer = hostLayer
        wantsLayer = true
        spriteLayer.contentsGravity = .resize
        spriteLayer.minificationFilter = .trilinear
        spriteLayer.magnificationFilter = .linear
        hostLayer.addSublayer(spriteLayer)

        // Accept files dropped on the pet
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// Tells whether a mouse press on the pet is still in progress.
    var isTrackingPress: Bool {
        return pressLocation != nil
    }

    /// Sizes the drawing and turns it by counterclockwise quarter turns.
    func arrangeSprite(uprightSize: CGSize, quarterTurns: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.bounds = CGRect(origin: .zero, size: uprightSize)
        spriteLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        spriteLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2))
        CATransaction.commit()
    }

    /// Shows one frame without a fade.
    func show(frame image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = image
        CATransaction.commit()
    }

    /// Draws the view's layers into a bitmap on a grey background.
    func renderSnapshot(scale: CGFloat) -> CGImage? {
        guard let hostLayer = layer else {
            return nil
        }
        let pixelWidth = Int(bounds.width * scale)
        let pixelHeight = Int(bounds.height * scale)
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let bitmapContext = context else {
            return nil
        }
        bitmapContext.setFillColor(CGColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        bitmapContext.scaleBy(x: scale, y: scale)
        hostLayer.render(in: bitmapContext)
        return bitmapContext.makeImage()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Remember where the press started
        let location = NSEvent.mouseLocation
        pressLocation = location
        isDragging = false
        dragSamples = [DragSample(time: event.timestamp, location: location)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation = pressLocation else {
            return
        }
        let location = NSEvent.mouseLocation

        // Start the drag once the mouse has moved far enough
        if !isDragging {
            let distance = hypot(location.x - pressLocation.x, location.y - pressLocation.y)
            guard distance >= PetConfig.dragStartDistance else {
                return
            }
            isDragging = true
            delegate?.petViewDidBeginDrag(at: pressLocation)
        }

        // Follow the mouse
        dragSamples.append(DragSample(time: event.timestamp, location: location))
        dragSamples = Array(dragSamples.suffix(6))
        delegate?.petViewDidDrag(to: location)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressLocation != nil else {
            return
        }

        // Finish the gesture
        if isDragging {
            delegate?.petViewDidEndDrag(velocity: releaseVelocity(at: event.timestamp))
        } else {
            delegate?.petViewWasClicked()
        }
        pressLocation = nil
        isDragging = false
        dragSamples = []
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = delegate?.petViewMenu() else {
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Read the dropped file locations
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        let fileURLs = objects as? [URL] ?? []
        guard !fileURLs.isEmpty else {
            return false
        }
        delegate?.petViewDidReceiveFiles(fileURLs)
        return true
    }

    /// Estimates how fast the mouse was moving when it let go.
    private func releaseVelocity(at releaseTime: TimeInterval) -> CGVector {
        let recentSamples = dragSamples.filter { releaseTime - $0.time <= 0.12 }
        guard let first = recentSamples.first, let last = recentSamples.last else {
            return .zero
        }
        let duration = last.time - first.time
        guard duration > 0.01 else {
            return .zero
        }
        return CGVector(
            dx: (last.location.x - first.location.x) / CGFloat(duration),
            dy: (last.location.y - first.location.y) / CGFloat(duration)
        )
    }
}
