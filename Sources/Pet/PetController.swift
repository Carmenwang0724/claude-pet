import AppKit
import QuartzCore

/// Names a side edge of the screen.
enum WallSide {
    case left
    case right
}

/// Names which way the pet's feet point.
enum Posture {
    case upright
    case onLeftWall
    case onRightWall
    case underCeiling

    /// Gives the counterclockwise quarter turns applied to the upright drawing.
    var quarterTurns: Int {
        switch self {
        case .upright:
            return 0
        case .onLeftWall:
            return -1
        case .onRightWall:
            return 1
        case .underCeiling:
            return 2
        }
    }

    /// Gives a short name for the debug report.
    var name: String {
        switch self {
        case .upright:
            return "upright"
        case .onLeftWall:
            return "left-wall"
        case .onRightWall:
            return "right-wall"
        case .underCeiling:
            return "ceiling"
        }
    }
}

/// Names what the pet's body is doing.
enum Motion {
    case standing
    case walking(direction: CGFloat)
    case airborne
    case dragged
    case climbing(side: WallSide, direction: CGFloat)
    case hanging(direction: CGFloat)
    case sleeping
    case roaming(direction: CGFloat)

    /// Tells whether the pet rests on a ledge, awake or asleep.
    var isOnLedge: Bool {
        switch self {
        case .standing, .walking, .sleeping:
            return true
        case .airborne, .dragged, .climbing, .hanging, .roaming:
            return false
        }
    }

    /// Tells whether the pet is awake with a ledge under its feet.
    var isAwakeOnLedge: Bool {
        switch self {
        case .standing, .walking:
            return true
        case .airborne, .dragged, .climbing, .hanging, .sleeping, .roaming:
            return false
        }
    }

    /// Tells whether the pet is running freely across the desktop.
    var isRoaming: Bool {
        if case .roaming = self {
            return true
        }
        return false
    }

    /// Tells whether the pet is flying or falling.
    var isAirborne: Bool {
        if case .airborne = self {
            return true
        }
        return false
    }

    /// Tells whether the mouse is holding the pet.
    var isDragged: Bool {
        if case .dragged = self {
            return true
        }
        return false
    }

    /// Tells whether the pet is asleep.
    var isSleeping: Bool {
        if case .sleeping = self {
            return true
        }
        return false
    }

    /// Gives a short name for the debug report.
    var name: String {
        switch self {
        case .standing:
            return "standing"
        case .walking(let direction):
            return direction > 0 ? "walking-right" : "walking-left"
        case .airborne:
            return "airborne"
        case .dragged:
            return "dragged"
        case .climbing(_, let direction):
            if direction == 0 {
                return "climbing-rest"
            }
            return direction > 0 ? "climbing-up" : "climbing-down"
        case .hanging(let direction):
            if direction == 0 {
                return "hanging-rest"
            }
            return direction > 0 ? "hanging-right" : "hanging-left"
        case .sleeping:
            return "sleeping"
        case .roaming(let direction):
            if direction == 0 {
                return "roaming-rest"
            }
            return direction > 0 ? "roaming-right" : "roaming-left"
        }
    }
}

/// Runs the pet: the loop, the drawing, and the shared state used by every behaviour.
@MainActor
final class PetController: NSObject {
    // Hold the parts
    let panel: PetPanel
    let petView: PetView
    let bubble = BubblePanel()
    let board = ActivityBoard()
    let scanner = SurfaceScanner()
    let monitor = SessionMonitor()
    let mischief = DesktopMischief()
    var atlas: PetAtlas
    var timer: Timer?

    // Track the body
    var footPoint = CGPoint.zero
    var velocity = CGVector.zero
    var motion = Motion.airborne
    var support: Surface?
    var surfaces: [Surface] = []
    var displayScale: CGFloat
    var hasGreeted = false

    // Track the current plan
    var actionDeadline: TimeInterval = 0
    var walkTargetX: CGFloat?
    var isVisitingCursor = false
    var visitedCursorRestSince: TimeInterval = -1
    var wantsToClimb = false
    var climbTargetHeight: CGFloat?
    var climbLimits = CGRect.zero
    var hangTargetX: CGFloat?
    var pendingClaudeJumpTime: TimeInterval?

    // Track the mouse
    var grabOffset = CGSize.zero
    var lastDragLocation = CGPoint.zero
    var dragDirection: CGFloat = 1
    var lastDragMoveTime: TimeInterval = 0
    var lastMouseLocation = CGPoint.zero
    var simulatedMousePath: [CGPoint] = []
    var lastMouseSampleTime: TimeInterval = 0
    var mouseVelocity = CGVector.zero
    var mouseStillSince: TimeInterval = 0
    var startleCooldownUntil: TimeInterval = 0
    var pettingTravel: CGFloat = 0
    var pettingReversals = 0
    var pettingDirection: CGFloat = 0
    var pettingLastInsideTime: TimeInterval = 0
    var pettingCooldownUntil: TimeInterval = 0

    // Track the user's rhythm
    var nextActivityCheckTime: TimeInterval = 0
    var sleepBlockedUntil: TimeInterval = 0
    var workStartedAt: TimeInterval?
    var lastNightNudgeAt: TimeInterval = 0
    var nextMischiefTime: TimeInterval = 0
    var autoTidyTime: TimeInterval?
    var lastMischiefReport = ""
    var errand: DesktopErrand?
    var lastErrandSummary = ""

    // Track time
    var lastTickTime: TimeInterval = 0
    var currentStepsPerSecond: Double = 0
    var lastSurfaceScanTime: TimeInterval = 0
    var nextEventPollTime: TimeInterval = 0
    var rideBoostUntil: TimeInterval = 0
    var nextAttentionWaveTime: TimeInterval = 0
    var bubbleHideTime: TimeInterval?

    // Track the animation
    var player = AnimationPlayer()
    var oneShotClipName: String?
    var idlePoseClipName: String?
    var shownClipName = ""
    var shownFrameIndex = -1
    var arrangedSize = CGSize.zero
    var arrangedTurns = 0
    var currentMask: FrameMask?

    // Track Claude
    var agent = AgentSummary(state: .idle, label: nil)
    var bubbleText: String?
    var activities: [SessionActivity] = []
    var boardRows: [BoardRow] = []
    var isBoardHovered = false
    var lastOpenedLink = ""
    var isLinkOpeningDisabled = false

    // Hold the switches
    var isWanderingPaused: Bool
    var isClimbingEnabled: Bool
    var isMousePlayEnabled: Bool
    var areRemindersEnabled: Bool
    var isAutoMischiefEnabled: Bool
    var isBoardPinned: Bool

    init(atlas: PetAtlas) {
        // Read the saved preferences
        let defaults = UserDefaults.standard
        let storedScale = defaults.double(forKey: PetConfig.displayScaleKey)
        let scale = CGFloat(storedScale > 0 ? storedScale : PetConfig.defaultDisplayScale)
        let size = CGSize(width: atlas.cellPixelSize.width * scale, height: atlas.cellPixelSize.height * scale)

        // Build the window
        self.atlas = atlas
        self.displayScale = scale
        self.isWanderingPaused = defaults.bool(forKey: PetConfig.wanderingPausedKey)
        self.isClimbingEnabled = defaults.bool(forKey: PetConfig.climbingEnabledKey)
        self.isMousePlayEnabled = defaults.bool(forKey: PetConfig.mousePlayEnabledKey)
        self.areRemindersEnabled = defaults.bool(forKey: PetConfig.remindersEnabledKey)
        self.isAutoMischiefEnabled = defaults.bool(forKey: PetConfig.autoMischiefEnabledKey)
        self.isBoardPinned = defaults.bool(forKey: PetConfig.boardPinnedKey)
        self.panel = PetPanel.makeTransparent(size: size)
        self.petView = PetView(frame: CGRect(origin: .zero, size: size))
        super.init()
        panel.contentView = petView
        petView.delegate = self
        board.setSelectionHandler { [weak self] index in
            self?.openActivity(at: index)
        }
    }

    /// Brings the pet onto the screen and starts the loop.
    func start() {
        // Start from an empty event log
        monitor.prepare()

        // Set the clocks
        let now = CACurrentMediaTime()
        lastTickTime = now
        lastMouseLocation = NSEvent.mouseLocation
        lastMouseSampleTime = now
        mouseStillSince = now
        lastNightNudgeAt = now - PetConfig.nightNudgeInterval + PetConfig.firstNightNudgeDelay
        nextMischiefTime = now + randomMischiefGap()
        if mischief.hasSnapshot {
            autoTidyTime = now + PetConfig.autoTidyMinimumDelay
        }

        // Enter the screen
        enterScreen()
        panel.orderFrontRegardless()

        // Run the loop
        scheduleLoop(stepsPerSecond: PetConfig.fastStepsPerSecond)

        // Hand the memory used while cutting the atlas back to the system
        perform(#selector(releaseUnusedMemory), with: nil, afterDelay: PetConfig.memoryReliefDelay)
    }

    /// Returns freed memory to the system.
    @objc func releaseUnusedMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Restarts the loop timer at a given rate.
    func scheduleLoop(stepsPerSecond: Double) {
        timer?.invalidate()
        let interval = 1.0 / stepsPerSecond
        let loopTimer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        loopTimer.tolerance = interval * 0.1
        RunLoop.main.add(loopTimer, forMode: .common)
        timer = loopTimer
        currentStepsPerSecond = stepsPerSecond
    }

    // MARK: - Sizes

    /// Gives the size of the upright drawing in points.
    var uprightSize: CGSize {
        return CGSize(
            width: atlas.cellPixelSize.width * displayScale,
            height: atlas.cellPixelSize.height * displayScale
        )
    }

    /// Gives the height of the drawn body in points.
    var bodyHeight: CGFloat {
        let bodyPixels = atlas.cellPixelSize.height - atlas.headInsetPixels - atlas.footInsetPixels
        return bodyPixels * displayScale
    }

    /// Gives the distance kept between the pet's middle and a screen edge.
    var halfBodyWidth: CGFloat {
        return uprightSize.width * 0.3
    }

    /// Gives the empty margin under the feet in points.
    var footInset: CGFloat {
        return atlas.footInsetPixels * displayScale
    }

    /// Tells which way the feet point for the current motion.
    var posture: Posture {
        switch motion {
        case .climbing(let side, _):
            return side == .left ? .onLeftWall : .onRightWall
        case .hanging:
            return .underCeiling
        case .standing, .walking, .airborne, .dragged, .sleeping, .roaming:
            return .upright
        }
    }

    /// Tells whether Claude needs the pet to stand still and show a status.
    var holdsStage: Bool {
        switch agent.state {
        case .waitingForPermission, .waitingForAnswer, .review:
            return true
        case .idle, .running:
            return false
        }
    }

    /// Picks how many steps per second the current state needs.
    var neededStepsPerSecond: Double {
        // Stay quick while flying, held or running across the desktop
        if motion.isAirborne || motion.isDragged || motion.isRoaming || petView.isTrackingPress {
            return PetConfig.fastStepsPerSecond
        }

        // Stay responsive with the cursor close by
        let alertZone = panel.frame.insetBy(dx: -PetConfig.alertDistance, dy: -PetConfig.alertDistance)
        if alertZone.contains(lastMouseLocation) || isBoardHovered {
            return PetConfig.alertStepsPerSecond
        }

        // Slow down with the body
        switch motion {
        case .walking, .climbing, .hanging, .airborne, .dragged, .roaming:
            return PetConfig.movingStepsPerSecond
        case .sleeping:
            return PetConfig.sleepingStepsPerSecond
        case .standing:
            return oneShotClipName == nil ? PetConfig.calmStepsPerSecond : PetConfig.movingStepsPerSecond
        }
    }

    /// Gives the wait between two window scans for the current state.
    func surfaceScanInterval(now: TimeInterval) -> TimeInterval {
        if now < rideBoostUntil {
            return PetConfig.ridingScanInterval
        }
        if motion.isAirborne {
            return PetConfig.airborneScanInterval
        }
        if motion.isSleeping {
            return PetConfig.sleepingScanInterval
        }
        let standsOnWindow = support?.isFloor == false
        return standsOnWindow ? PetConfig.windowScanInterval : PetConfig.floorScanInterval
    }

    /// Returns the visible frame of the screen nearest to a point.
    func screenFrame(near point: CGPoint) -> CGRect {
        let screens = NSScreen.screens
        if let screen = screens.first(where: { $0.frame.contains(point) }) {
            return screen.visibleFrame
        }
        if let screen = screens.first(where: { point.x >= $0.frame.minX && point.x <= $0.frame.maxX }) {
            return screen.visibleFrame
        }
        let fallbackScreen = NSScreen.main ?? screens.first
        return fallbackScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Returns the floor under a point.
    func floorSurface(near point: CGPoint) -> Surface? {
        let floors = surfaces.filter { $0.isFloor }
        if let floor = floors.first(where: { $0.contains(x: point.x) }) {
            return floor
        }
        return floors.first
    }

    /// Computes the window frame that puts the feet on the contact point.
    func panelFrame() -> CGRect {
        let size = uprightSize
        switch posture {
        case .upright:
            return CGRect(
                x: footPoint.x - size.width / 2,
                y: footPoint.y - footInset,
                width: size.width,
                height: size.height
            )
        case .onLeftWall:
            return CGRect(
                x: footPoint.x - footInset,
                y: footPoint.y - size.width / 2,
                width: size.height,
                height: size.width
            )
        case .onRightWall:
            return CGRect(
                x: footPoint.x - size.height + footInset,
                y: footPoint.y - size.width / 2,
                width: size.height,
                height: size.width
            )
        case .underCeiling:
            return CGRect(
                x: footPoint.x - size.width / 2,
                y: footPoint.y - size.height + footInset,
                width: size.width,
                height: size.height
            )
        }
    }

    // MARK: - Loop

    /// Advances the pet by one step.
    @objc func tick() {
        // Measure the time since the last step
        let now = CACurrentMediaTime()
        let elapsed = min(now - lastTickTime, PetConfig.longestStep)
        lastTickTime = now

        // Update what is known about Claude, the screen and the user
        pollAgentIfDue(now: now)
        scanSurfacesIfDue(now: now)
        trackMouse(now: now)
        trackActivityIfDue(now: now)
        hopToClaudeWindowIfDue(now: now)

        // Move, animate and draw
        stepMotion(elapsed: elapsed, now: now)
        stepAnimation(elapsed: elapsed)
        placeWindows(now: now)
        updateMousePassThrough()

        // Match the loop rate to what is going on
        let neededRate = neededStepsPerSecond
        if neededRate != currentStepsPerSecond {
            scheduleLoop(stepsPerSecond: neededRate)
        }
    }

    /// Rescans the windows at the pace the current state needs.
    func scanSurfacesIfDue(now: TimeInterval) {
        guard now - lastSurfaceScanTime >= surfaceScanInterval(now: now) else {
            return
        }
        lastSurfaceScanTime = now
        surfaces = scanner.scan(clearance: bodyHeight)
        followSupport(now: now)
    }

    // MARK: - Animation

    /// Names the clip that fits the current motion and Claude state.
    func desiredClipName() -> String {
        if let oneShotClipName = oneShotClipName {
            return oneShotClipName
        }
        switch motion {
        case .airborne:
            return "jumping"
        case .dragged:
            let isBeingPulled = CACurrentMediaTime() - lastDragMoveTime < PetConfig.dragWalkLinger
            guard isBeingPulled else {
                return "jumping"
            }
            return dragDirection > 0 ? "walk-right" : "walk-left"
        case .walking(let direction):
            return direction > 0 ? "walk-right" : "walk-left"
        case .climbing(let side, let direction):
            guard direction != 0 else {
                return "idle"
            }
            let usesRightFacingClip = (side == .right) == (direction > 0)
            return usesRightFacingClip ? "walk-right" : "walk-left"
        case .hanging(let direction):
            guard direction != 0 else {
                return "idle"
            }
            return direction > 0 ? "walk-left" : "walk-right"
        case .sleeping:
            return "sleeping"
        case .roaming(let direction):
            guard direction != 0 else {
                return "jumping"
            }
            return direction > 0 ? "walk-right" : "walk-left"
        case .standing:
            switch agent.state {
            case .waitingForPermission, .waitingForAnswer:
                return "waiting"
            case .review:
                return "review"
            case .idle, .running:
                return idlePoseClipName ?? "idle"
            }
        }
    }

    /// Plays a clip once, then returns to the regular clip.
    func playOnce(_ clipName: String) {
        guard motion.isAwakeOnLedge else {
            return
        }
        oneShotClipName = clipName
        player.restart(clipName)
    }

    /// Advances the clip and draws the frame when it changed.
    func stepAnimation(elapsed: TimeInterval) {
        // Drop a one-time clip when the pet leaves its ledge
        if !motion.isAwakeOnLedge {
            oneShotClipName = nil
        }

        // Advance the current clip, with quicker legs on a run across the desktop
        var clipName = desiredClipName()
        player.play(clipName)
        var clip = atlas.clip(named: clipName)
        var pace = 1.0
        if case .roaming(let direction) = motion, direction != 0 {
            pace = PetConfig.errandAnimationRate
        }
        player.advance(elapsed: elapsed * pace, clip: clip)

        // Return to the regular clip after a one-time clip has played
        if oneShotClipName != nil && player.completedCycles >= 1 {
            oneShotClipName = nil
            clipName = desiredClipName()
            player.restart(clipName)
            clip = atlas.clip(named: clipName)
        }

        // Draw the frame when it changed
        let frameIndex = min(player.frameIndex, clip.frameCount - 1)
        if clipName != shownClipName || frameIndex != shownFrameIndex {
            let frames = atlas.frames(forClipNamed: clipName)
            guard frameIndex < frames.count else {
                return
            }
            petView.show(frame: frames[frameIndex])
            shownClipName = clipName
            shownFrameIndex = frameIndex
            currentMask = clip.masks[frameIndex]
        }
    }

    // MARK: - Windows

    /// Moves the pet window and the bubble to match the contact point.
    func placeWindows(now: TimeInterval) {
        // Place the pet window
        let exactFrame = panelFrame()
        let frame = CGRect(
            x: (exactFrame.minX * 2).rounded() / 2,
            y: (exactFrame.minY * 2).rounded() / 2,
            width: exactFrame.width,
            height: exactFrame.height
        )
        if panel.frame.size != frame.size {
            panel.setFrame(frame, display: false)
        } else if panel.frame.origin != frame.origin {
            panel.setFrameOrigin(frame.origin)
        }

        // Turn the drawing to match the posture
        let quarterTurns = posture.quarterTurns
        if frame.size != arrangedSize || quarterTurns != arrangedTurns {
            petView.arrangeSprite(uprightSize: uprightSize, quarterTurns: quarterTurns)
            arrangedSize = frame.size
            arrangedTurns = quarterTurns
        }

        // Place the carried icon, the activity board and the bubble
        placeCarriedIcon(now: now)
        placeOverlays(petFrame: frame, now: now)
    }

    /// Shows a short message above the pet for a few seconds.
    func showTransientBubble(_ text: String, duration: TimeInterval, now: TimeInterval) {
        bubbleText = text
        bubbleHideTime = now + duration
    }

    /// Lets clicks through wherever the current frame is transparent.
    func updateMousePassThrough() {
        var shouldIgnore = true
        if motion.isDragged || petView.isTrackingPress {
            shouldIgnore = false
        } else if let mask = currentMask {
            let mouse = NSEvent.mouseLocation
            let frame = panel.frame
            if frame.contains(mouse) {
                shouldIgnore = !isOpaque(mask: mask, at: mouse, in: frame)
            }
        }
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
    }

    /// Looks up the opacity of the turned drawing under a screen point.
    func isOpaque(mask: FrameMask, at point: CGPoint, in frame: CGRect) -> Bool {
        // Measure the point from the middle of the window
        let offsetX = point.x - frame.midX
        let offsetY = point.y - frame.midY

        // Turn the offset back into the upright drawing
        let uprightX: CGFloat
        let uprightY: CGFloat
        switch posture {
        case .upright:
            uprightX = offsetX
            uprightY = offsetY
        case .onLeftWall:
            uprightX = -offsetY
            uprightY = offsetX
        case .onRightWall:
            uprightX = offsetY
            uprightY = -offsetX
        case .underCeiling:
            uprightX = -offsetX
            uprightY = -offsetY
        }

        // Read the mask from its top-left corner
        let size = uprightSize
        let normalizedX = (uprightX + size.width / 2) / size.width
        let normalizedY = (size.height / 2 - uprightY) / size.height
        return mask.isOpaque(normalizedX: normalizedX, normalizedY: normalizedY)
    }
}
