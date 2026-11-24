import AppKit

/// Names the two kinds of desktop trip.
enum ErrandKind {
    case mess
    case tidy

    /// Gives a short name for the debug report.
    var name: String {
        switch self {
        case .mess:
            return "mess"
        case .tidy:
            return "tidy"
        }
    }
}

/// Names the part of a desktop trip the pet is in.
enum ErrandStage {
    case approaching
    case lifting
    case carrying
    case lowering
    case tossing

    /// Gives a short name for the debug report.
    var name: String {
        switch self {
        case .approaching:
            return "approaching"
        case .lifting:
            return "lifting"
        case .carrying:
            return "carrying"
        case .lowering:
            return "lowering"
        case .tossing:
            return "tossing"
        }
    }
}

/// Describes one icon to move, with places given as icon centres in screen coordinates.
struct ErrandJob {
    let iconName: String
    let pickupPoint: CGPoint
    let dropPoint: CGPoint?
    let finalX: Int
    let finalY: Int
}

/// Holds the state of one desktop trip.
@MainActor
final class DesktopErrand {
    let kind: ErrandKind
    let isUserRequest: Bool
    let isRehearsal: Bool
    let limits: CGRect
    let iconSize: CGFloat
    let startedAt: TimeInterval
    let jobs: [ErrandJob]
    let mover = DesktopIconMover()

    // Track the route
    var jobIndex = 0
    var stage = ErrandStage.approaching
    var stageStartedAt: TimeInterval
    var route: [CGPoint] = []
    var facing: CGFloat = 1

    // Track the icon in hand
    var iconPoint = CGPoint.zero
    var isHoldingIcon = false
    var isIconCovered = false
    var iconPanel: CarriedIconPanel?
    var lastSentX = Int.min
    var lastSentY = Int.min
    var nextSendTime: TimeInterval = 0
    var failedSends = 0
    var movedCount = 0

    // Track the windows that hide the desktop
    var windowFrames: [CGRect] = []
    var nextWindowScanTime: TimeInterval = 0

    init(
        kind: ErrandKind,
        jobs: [ErrandJob],
        isUserRequest: Bool,
        isRehearsal: Bool,
        limits: CGRect,
        iconSize: CGFloat,
        now: TimeInterval
    ) {
        self.kind = kind
        self.jobs = jobs
        self.isUserRequest = isUserRequest
        self.isRehearsal = isRehearsal
        self.limits = limits
        self.iconSize = iconSize
        self.startedAt = now
        self.stageStartedAt = now
    }

    /// Returns the icon being fetched or carried.
    var currentJob: ErrandJob? {
        return jobIndex < jobs.count ? jobs[jobIndex] : nil
    }

    /// Sums up the trip for the debug report, without naming any file.
    var summary: String {
        let lastMilliseconds = Int((mover.lastSendDuration * 1000).rounded())
        let slowestMilliseconds = Int((mover.slowestSendDuration * 1000).rounded())
        let label = isRehearsal ? "rehearsal" : kind.name
        let iconText = isHoldingIcon ? "icon at \(Int(iconPoint.x)) \(Int(iconPoint.y)) \(isIconCovered ? "covered" : "in view")" : "no icon"
        return "\(label) \(stage.name) icon \(min(jobIndex + 1, jobs.count))/\(jobs.count), \(iconText), "
            + "moved \(movedCount), sends \(mover.sendCount), failed \(mover.failureCount), "
            + "last \(lastMilliseconds) ms, slowest \(slowestMilliseconds) ms, last error \(mover.lastErrorNumber)"
    }
}

/// Runs the trips to the desktop: running to icons, carrying them off, and bringing them back.
extension PetController {
    // MARK: - Requests

    /// Picks the wait before the next unprompted desktop trip.
    func randomMischiefGap() -> TimeInterval {
        return Double.random(in: PetConfig.autoMischiefMinimumGap...PetConfig.autoMischiefMaximumGap)
    }

    /// Tells whether Claude is waiting for the user right now.
    var needsUserNow: Bool {
        return agent.state == .waitingForPermission || agent.state == .waitingForAnswer
    }

    /// Gets ready to carry some desktop icons away.
    func startMischief(iconCount: Int, isUserRequest: Bool, now: TimeInterval) {
        guard errand == nil, !mischief.isBusy, !motion.isDragged else {
            return
        }

        // Look keen while Finder answers a request from the menu
        if isUserRequest && motion.isAwakeOnLedge {
            motion = .standing
            clearPlan()
            idlePoseClipName = "waving"
            actionDeadline = now + 6
        }

        // Ask Finder which icons can be taken; only a request from the menu may switch off
        // a sort order that has to be switched back on by hand
        let hasAcceptedManualSort = UserDefaults.standard.bool(forKey: PetConfig.manualSortAcceptedKey)
        let allowsManualSort = isUserRequest && hasAcceptedManualSort
        mischief.prepareMess(iconCount: iconCount, allowsManualSort: allowsManualSort) { [weak self] preparation in
            self?.beginMess(preparation: preparation, iconCount: iconCount, isUserRequest: isUserRequest)
        }
    }

    /// Sets off once Finder has named the icons, or says why not.
    func beginMess(preparation: MessPreparation, iconCount: Int, isUserRequest: Bool) {
        let now = CACurrentMediaTime()
        switch preparation {
        case .ready(let icons):
            // The layout is saved from here on, so a tidy-up is owed whatever happens next
            planTidy(now: now)
            if nextMischiefTime == .infinity {
                nextMischiefTime = now + randomMischiefGap()
            }
            guard let limits = desktopLimits(), !motion.isDragged, errand == nil else {
                lastMischiefReport = "mess skipped"
                return
            }
            let jobs = makeMessJobs(icons: icons, limits: limits)
            beginErrand(
                kind: .mess,
                jobs: jobs,
                isUserRequest: isUserRequest,
                isRehearsal: false,
                limits: limits,
                now: now
            )
            showTransientBubble("Ooh, files!", duration: 3, now: now)
        case .needsConfirmation(let sortName):
            lastMischiefReport = "needs confirmation: \(sortName)"
            if isUserRequest {
                confirmManualSort(sortName: sortName, iconCount: iconCount)
            }
        case .notAllowed:
            reportMischief(outcome: .notAllowed, successText: "", isUserRequest: isUserRequest)
        case .failed(let message):
            reportMischief(outcome: .failed(message: message), successText: "", isUserRequest: isUserRequest)
        }
    }

    /// Sets the time of the tidy-up that follows a mess.
    func planTidy(now: TimeInterval) {
        let delay = Double.random(in: PetConfig.autoTidyMinimumDelay...PetConfig.autoTidyMaximumDelay)
        autoTidyTime = now + delay
    }

    /// Gets ready to bring the desktop icons back.
    func startTidy(isUserRequest: Bool, now: TimeInterval) {
        guard errand == nil, !mischief.isBusy, !motion.isDragged else {
            return
        }
        autoTidyTime = nil

        // Put everything back at once when nobody is watching
        let isUnwatched = motion.isSleeping || idleSeconds() >= PetConfig.awayIdleTime
        if isUnwatched && !isUserRequest {
            restoreDesktopAtOnce(isUserRequest: false)
            return
        }

        // Ask Finder which icons are out of place
        mischief.prepareTidy { [weak self] preparation in
            self?.beginTidy(preparation: preparation, isUserRequest: isUserRequest)
        }
    }

    /// Sets off to carry the stray icons home, or finishes at once when there is nothing to carry.
    func beginTidy(preparation: TidyPreparation, isUserRequest: Bool) {
        let now = CACurrentMediaTime()
        switch preparation {
        case .ready(let strays):
            guard !strays.isEmpty, let limits = desktopLimits(), !motion.isDragged, errand == nil else {
                restoreDesktopAtOnce(isUserRequest: isUserRequest)
                return
            }
            let jobs = makeTidyJobs(strays: strays, limits: limits)
            beginErrand(
                kind: .tidy,
                jobs: jobs,
                isUserRequest: isUserRequest,
                isRehearsal: false,
                limits: limits,
                now: now
            )
            showTransientBubble("Okay, okay. Tidying up.", duration: 3, now: now)
        case .notAllowed:
            reportMischief(outcome: .notAllowed, successText: "", isUserRequest: isUserRequest)
        case .failed(let message):
            // Try again later when Finder could not answer this time
            autoTidyTime = now + PetConfig.autoTidyMaximumDelay
            reportMischief(outcome: .failed(message: message), successText: "", isUserRequest: isUserRequest)
        }
    }

    /// Puts every icon back in one go and reports how it went.
    func restoreDesktopAtOnce(isUserRequest: Bool) {
        mischief.finishTidy { [weak self] outcome in
            // Try again later when Finder could not do it this time
            if case .failed = outcome {
                self?.autoTidyTime = CACurrentMediaTime() + PetConfig.autoTidyMaximumDelay
            }
            self?.reportMischief(outcome: outcome, successText: "All tidy", isUserRequest: isUserRequest)
        }
    }

    /// Turns the result of a desktop request into a bubble.
    func reportMischief(outcome: MischiefOutcome, successText: String, isUserRequest: Bool) {
        let now = CACurrentMediaTime()
        switch outcome {
        case .done(let detail):
            lastMischiefReport = "done: \(detail)"
            showTransientBubble(successText, duration: 6, now: now)
            playOnce("jumping")
        case .doneNeedingManualSort(let sortName):
            lastMischiefReport = "done, manual sort needed: \(sortName)"
            showTransientBubble("Icons are back in place. Re-select Sort By > \(sortName) on the desktop to sort again.", duration: 15, now: now)
            playOnce("jumping")
        case .notAllowed:
            // Stop the unprompted trips until the switch in the menu is used again
            lastMischiefReport = "not allowed"
            nextMischiefTime = .infinity
            autoTidyTime = nil
            showTransientBubble("Allow me to control Finder in System Settings first", duration: 10, now: now)
        case .failed(let message):
            lastMischiefReport = "failed: \(message)"
            if isUserRequest {
                showTransientBubble(message, duration: 12, now: now)
            }
        }
    }

    /// Asks whether to go ahead when the desktop sorting must be switched back on by hand.
    func confirmManualSort(sortName: String, iconCount: Int) {
        // Explain what will and will not be restored
        let alert = NSAlert()
        alert.messageText = "Before I mess things up"
        alert.informativeText = "Your desktop is sorted by \(sortName). I have to turn that sorting off before I can move icons. Tidying puts every icon back where it was, but you will need to re-select Sort By > \(sortName) from the desktop's right-click menu yourself."
        alert.addButton(withTitle: "Go ahead")
        alert.addButton(withTitle: "Never mind")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        // Remember the answer and go ahead
        UserDefaults.standard.set(true, forKey: PetConfig.manualSortAcceptedKey)
        startMischief(iconCount: iconCount, isUserRequest: true, now: CACurrentMediaTime())
    }

    /// Runs a trip with made-up icons that never touches Finder, to check the moves.
    func rehearseErrand(now: TimeInterval) {
        guard errand == nil, !motion.isDragged, let limits = desktopLimits() else {
            return
        }

        // Make up three icons, the last of which is handed back instead of carried
        let iconSize = mischief.desktopIconSize
        var jobs: [ErrandJob] = []
        var position = footPoint
        for index in 1...3 {
            let pickupPoint = randomPilePoint(near: position, limits: limits, iconSize: iconSize)
            let dropPoint = randomDropPoint(near: pickupPoint, limits: limits, iconSize: iconSize)
            let finalPlace = finderPlace(of: dropPoint)
            position = dropPoint
            jobs.append(
                ErrandJob(
                    iconName: "Rehearsal \(index).txt",
                    pickupPoint: pickupPoint,
                    dropPoint: index == 3 ? nil : dropPoint,
                    finalX: finalPlace.x,
                    finalY: finalPlace.y
                )
            )
        }
        beginErrand(kind: .mess, jobs: jobs, isUserRequest: true, isRehearsal: true, limits: limits, now: now)
    }

    // MARK: - Planning

    /// Returns the part of the main screen the pet may run in.
    func desktopLimits() -> CGRect? {
        return NSScreen.screens.first?.visibleFrame
    }

    /// Plans where each chosen icon is picked up and where it is left.
    func makeMessJobs(icons: [DesktopIcon], limits: CGRect) -> [ErrandJob] {
        let iconSize = mischief.desktopIconSize
        var jobs: [ErrandJob] = []
        var position = footPoint
        for icon in icons {
            // Go to the icon when its place is known, else to a spot among the icons nearby
            var pickupPoint = randomPilePoint(near: position, limits: limits, iconSize: iconSize)
            if icon.isPlaced {
                pickupPoint = screenPoint(finderX: icon.x, finderY: icon.y)
            }

            // Leave it a short run away
            let dropPoint = randomDropPoint(near: pickupPoint, limits: limits, iconSize: iconSize)
            let finalPlace = finderPlace(of: dropPoint)
            jobs.append(
                ErrandJob(
                    iconName: icon.name,
                    pickupPoint: pickupPoint,
                    dropPoint: dropPoint,
                    finalX: finalPlace.x,
                    finalY: finalPlace.y
                )
            )
            position = dropPoint
        }
        return jobs
    }

    /// Plans the way home for the stray icons, nearest first.
    func makeTidyJobs(strays: [StrayIcon], limits: CGRect) -> [ErrandJob] {
        let iconSize = mischief.desktopIconSize
        var remaining = strays
        var jobs: [ErrandJob] = []
        var position = footPoint
        while !remaining.isEmpty && jobs.count < PetConfig.errandTidyLimit {
            // Work out where every stray left is picked up
            let pickupPoints = remaining.map { stray -> CGPoint in
                let hasKnownPlace = stray.currentX >= 0 && stray.currentY >= 0
                guard hasKnownPlace else {
                    return randomPilePoint(near: position, limits: limits, iconSize: iconSize)
                }
                return screenPoint(finderX: stray.currentX, finderY: stray.currentY)
            }

            // Take the one nearest to where the pet will be
            var nearestIndex = 0
            var nearestDistance = CGFloat.greatestFiniteMagnitude
            for index in 0..<remaining.count {
                let distance = hypot(pickupPoints[index].x - position.x, pickupPoints[index].y - position.y)
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = index
                }
            }
            let stray = remaining.remove(at: nearestIndex)
            let pickupPoint = pickupPoints[nearestIndex]

            // Carry it home, or hand it back to Finder when Finder chose its place
            let hasKnownHome = stray.homeX >= 0 && stray.homeY >= 0
            let dropPoint: CGPoint? = hasKnownHome ? screenPoint(finderX: stray.homeX, finderY: stray.homeY) : nil
            jobs.append(
                ErrandJob(
                    iconName: stray.name,
                    pickupPoint: pickupPoint,
                    dropPoint: dropPoint,
                    finalX: stray.homeX,
                    finalY: stray.homeY
                )
            )
            position = dropPoint ?? pickupPoint
        }
        return jobs
    }

    /// Picks a spot near a point, on the side of the screen where Finder lines the icons up.
    func randomPilePoint(near point: CGPoint, limits: CGRect, iconSize: CGFloat) -> CGPoint {
        let margin = PetConfig.errandEdgeMargin
        let minimumX = limits.minX + limits.width * 0.45
        let maximumX = max(limits.maxX - margin, minimumX)
        let minimumY = limits.minY + limits.height * 0.3
        let maximumY = max(limits.maxY - iconSize, minimumY)
        let area = CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
        return randomPoint(near: point, distances: PetConfig.errandFetchReach, within: area)
    }

    /// Picks a spot near a point where an icon and its name stay on the screen.
    func randomDropPoint(near point: CGPoint, limits: CGRect, iconSize: CGFloat) -> CGPoint {
        let margin = PetConfig.errandEdgeMargin
        let minimumX = limits.minX + margin
        let maximumX = max(limits.maxX - margin, minimumX)
        let minimumY = limits.minY + iconSize + 8
        let maximumY = max(limits.maxY - iconSize, minimumY)
        let area = CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
        return randomPoint(near: point, distances: PetConfig.errandCarryReach, within: area)
    }

    /// Picks a spot inside an area at a comfortable run from a point.
    func randomPoint(near point: CGPoint, distances: ClosedRange<CGFloat>, within area: CGRect) -> CGPoint {
        // Try a few directions and keep the first spot that lands inside the area
        for _ in 0..<16 {
            let angle = CGFloat.random(in: 0..<(2 * CGFloat.pi))
            let distance = CGFloat.random(in: distances)
            let candidate = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance)
            if area.contains(candidate) {
                return candidate
            }
        }

        // Fall back to anywhere in the area
        return CGPoint(
            x: CGFloat.random(in: area.minX...area.maxX),
            y: CGFloat.random(in: area.minY...area.maxY)
        )
    }

    /// Converts a place in Finder's desktop coordinates into a screen point.
    func screenPoint(finderX: Int, finderY: Int) -> CGPoint {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: CGFloat(finderX), y: screenTop - CGFloat(finderY))
    }

    /// Converts a screen point into Finder's desktop coordinates.
    func finderPlace(of point: CGPoint) -> (x: Int, y: Int) {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let finderX = Int(point.x.rounded())
        let finderY = Int((screenTop - point.y).rounded())
        return (max(finderX, 0), max(finderY, 0))
    }

    /// Keeps the feet where the whole body stays inside the limits.
    func clampedFoot(_ foot: CGPoint, limits: CGRect) -> CGPoint {
        let minimumX = limits.minX + halfBodyWidth
        let maximumX = max(limits.maxX - halfBodyWidth, minimumX)
        let minimumY = limits.minY
        let maximumY = max(limits.maxY - bodyHeight, minimumY)
        return CGPoint(
            x: min(max(foot.x, minimumX), maximumX),
            y: min(max(foot.y, minimumY), maximumY)
        )
    }

    /// Returns where the feet go so that an icon sits at chest height.
    func standPoint(forIconAt iconPoint: CGPoint, limits: CGRect) -> CGPoint {
        let foot = CGPoint(x: iconPoint.x, y: iconPoint.y - bodyHeight * PetConfig.errandChestHeight)
        return clampedFoot(foot, limits: limits)
    }

    /// Returns where the icon rides above the head.
    func carryPoint(trip: DesktopErrand) -> CGPoint {
        let ridingHeight = footPoint.y + bodyHeight + PetConfig.errandCarryGap + trip.iconSize / 2
        let highestHeight = trip.limits.maxY - trip.iconSize / 2 - 2
        return CGPoint(x: footPoint.x, y: min(ridingHeight, highestHeight))
    }

    /// Plans a path with a bend or two, so the pet weaves instead of running straight.
    func makeRoute(from start: CGPoint, to end: CGPoint, limits: CGRect) -> [CGPoint] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance >= PetConfig.errandStraightDistance else {
            return [end]
        }
        let bendCount = distance < PetConfig.errandSingleBendDistance ? 1 : 2

        // Swing to alternate sides of the straight line
        let sidewaysX = -(end.y - start.y) / distance
        let sidewaysY = (end.x - start.x) / distance
        var side: CGFloat = Bool.random() ? 1 : -1
        var route: [CGPoint] = []
        for bendIndex in 1...bendCount {
            let fraction = CGFloat(bendIndex) / CGFloat(bendCount + 1)
            let swing = side * CGFloat.random(in: PetConfig.errandBendOffset)
            let bend = CGPoint(
                x: start.x + (end.x - start.x) * fraction + sidewaysX * swing,
                y: start.y + (end.y - start.y) * fraction + sidewaysY * swing
            )
            route.append(clampedFoot(bend, limits: limits))
            side = -side
        }
        route.append(end)
        return route
    }

    // MARK: - Setting off

    /// Leaves the ledge and heads for the first icon.
    func beginErrand(
        kind: ErrandKind,
        jobs: [ErrandJob],
        isUserRequest: Bool,
        isRehearsal: Bool,
        limits: CGRect,
        now: TimeInterval
    ) {
        // Turn the body upright when it comes off a wall or the ceiling
        switch motion {
        case .climbing(let side, _):
            let inward: CGFloat = side == .left ? 1 : -1
            footPoint = CGPoint(
                x: footPoint.x + inward * uprightSize.height / 2,
                y: footPoint.y - uprightSize.height / 2
            )
        case .hanging:
            footPoint.y -= uprightSize.height
        case .standing, .walking, .airborne, .dragged, .sleeping, .roaming:
            break
        }

        // Let go of the ledge
        support = nil
        velocity = .zero
        clearPlan()
        oneShotClipName = nil
        motion = .roaming(direction: 0)

        // Set up the trip
        let trip = DesktopErrand(
            kind: kind,
            jobs: jobs,
            isUserRequest: isUserRequest,
            isRehearsal: isRehearsal,
            limits: limits,
            iconSize: mischief.desktopIconSize,
            now: now
        )
        errand = trip
        startApproach(trip: trip, now: now)
    }

    /// Plans the run to the next icon.
    func startApproach(trip: DesktopErrand, now: TimeInterval) {
        guard let job = trip.currentJob else {
            return
        }
        let target = standPoint(forIconAt: job.pickupPoint, limits: trip.limits)
        trip.route = makeRoute(from: footPoint, to: target, limits: trip.limits)
        trip.stage = .approaching
        trip.stageStartedAt = now
    }

    // MARK: - Steps

    /// Advances the trip by one step.
    func stepErrand(elapsed: CGFloat, now: TimeInterval) {
        guard let trip = errand else {
            startFalling()
            return
        }

        // Stop when Claude needs the user, or when the trip drags on
        if needsUserNow || now - trip.startedAt > PetConfig.errandTimeLimit {
            cutErrandShort(now: now, dropsToFloor: true)
            return
        }
        guard let job = trip.currentJob else {
            finishErrand(trip: trip, now: now)
            return
        }

        // Do what the current part of the trip asks for
        switch trip.stage {
        case .approaching:
            if runAlongRoute(trip: trip, speed: PetConfig.errandRunSpeed, elapsed: elapsed) {
                beginLift(trip: trip, job: job, now: now)
            }
        case .lifting:
            stepLifting(trip: trip, job: job, now: now)
        case .carrying:
            let hasArrived = runAlongRoute(trip: trip, speed: PetConfig.errandCarrySpeed, elapsed: elapsed)
            trip.iconPoint = carryPoint(trip: trip)
            guard sendIconIfDue(trip: trip, job: job, now: now) else {
                return
            }
            if hasArrived {
                trip.stage = .lowering
                trip.stageStartedAt = now
            }
        case .lowering:
            stepLowering(trip: trip, job: job, now: now)
        case .tossing:
            trip.iconPoint = carryPoint(trip: trip)
            if now - trip.stageStartedAt >= PetConfig.errandTossPause {
                settleIcon(trip: trip, job: job, now: now)
            }
        }
    }

    /// Runs along the route and reports whether its end was reached.
    func runAlongRoute(trip: DesktopErrand, speed: CGFloat, elapsed: CGFloat) -> Bool {
        var stride = speed * elapsed
        while stride > 0, let waypoint = trip.route.first {
            let offsetX = waypoint.x - footPoint.x
            let offsetY = waypoint.y - footPoint.y
            let distance = hypot(offsetX, offsetY)

            // Face the way the body is heading
            if abs(offsetX) > 1 {
                trip.facing = offsetX > 0 ? 1 : -1
            }

            // Pass through a waypoint that lies within this step
            if distance <= stride {
                footPoint = waypoint
                trip.route.removeFirst()
                stride -= distance
                continue
            }
            footPoint.x += offsetX / distance * stride
            footPoint.y += offsetY / distance * stride
            stride = 0
        }
        let hasArrived = trip.route.isEmpty
        motion = .roaming(direction: hasArrived ? 0 : trip.facing)
        return hasArrived
    }

    /// Takes hold of the icon the pet has just reached.
    func beginLift(trip: DesktopErrand, job: ErrandJob, now: TimeInterval) {
        // Put the icon in the pet's hands; this first move shows whether Finder allows it
        let place = finderPlace(of: job.pickupPoint)
        guard moveIcon(trip: trip, name: job.iconName, x: place.x, y: place.y) else {
            giveUpIcon(trip: trip, now: now)
            return
        }
        trip.iconPoint = job.pickupPoint
        trip.lastSentX = place.x
        trip.lastSentY = place.y
        trip.isHoldingIcon = true
        trip.failedSends = 0
        trip.nextSendTime = now + PetConfig.errandIconSendInterval

        // Prepare the copy shown wherever a window hides the real icon
        trip.iconPanel = CarriedIconPanel(fileName: job.iconName, iconSize: trip.iconSize)
        trip.stage = .lifting
        trip.stageStartedAt = now
        motion = .roaming(direction: 0)
    }

    /// Raises the icon from where it lay to above the head.
    func stepLifting(trip: DesktopErrand, job: ErrandJob, now: TimeInterval) {
        let progress = min((now - trip.stageStartedAt) / PetConfig.errandLiftDuration, 1)
        let easedProgress = 1 - (1 - progress) * (1 - progress)
        trip.iconPoint = blend(from: job.pickupPoint, to: carryPoint(trip: trip), progress: CGFloat(easedProgress))
        guard sendIconIfDue(trip: trip, job: job, now: now) else {
            return
        }
        guard progress >= 1 else {
            return
        }

        // Run off with it, or hand it back to Finder when Finder chose its place
        if let dropPoint = job.dropPoint {
            let target = standPoint(forIconAt: dropPoint, limits: trip.limits)
            trip.route = makeRoute(from: footPoint, to: target, limits: trip.limits)
            trip.stage = .carrying
        } else {
            trip.stage = .tossing
        }
        trip.stageStartedAt = now
    }

    /// Brings the icon down from above the head to where it is left.
    func stepLowering(trip: DesktopErrand, job: ErrandJob, now: TimeInterval) {
        let progress = min((now - trip.stageStartedAt) / PetConfig.errandLowerDuration, 1)
        let dropPoint = job.dropPoint ?? trip.iconPoint
        trip.iconPoint = blend(from: carryPoint(trip: trip), to: dropPoint, progress: CGFloat(progress))
        guard sendIconIfDue(trip: trip, job: job, now: now) else {
            return
        }
        if progress >= 1 {
            settleIcon(trip: trip, job: job, now: now)
        }
    }

    /// Returns the point part of the way from one point to another.
    func blend(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        return CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    /// Moves the real icon to where the pet holds it, as often as Finder keeps up with.
    /// Returns false when the icon or the whole trip had to be given up.
    func sendIconIfDue(trip: DesktopErrand, job: ErrandJob, now: TimeInterval) -> Bool {
        guard trip.isHoldingIcon, now >= trip.nextSendTime else {
            return true
        }
        let place = finderPlace(of: trip.iconPoint)
        guard place.x != trip.lastSentX || place.y != trip.lastSentY else {
            return true
        }

        // Move the icon, then wait longer when Finder was slow
        let isMoved = moveIcon(trip: trip, name: job.iconName, x: place.x, y: place.y)
        let sendCost = trip.mover.lastSendDuration * PetConfig.errandSendLoad
        trip.nextSendTime = now + max(PetConfig.errandIconSendInterval, sendCost)
        if isMoved {
            trip.lastSentX = place.x
            trip.lastSentY = place.y
            trip.failedSends = 0
            return true
        }

        // Let go after repeated failures, or at once when Finder refuses or does not answer
        trip.failedSends += 1
        let isHopeless = trip.mover.wasRefused || trip.mover.hasTimedOut
        guard isHopeless || trip.failedSends >= PetConfig.errandSendFailureLimit else {
            return true
        }
        giveUpIcon(trip: trip, now: now)
        return false
    }

    /// Moves the real icon, or only pretends to during a rehearsal.
    func moveIcon(trip: DesktopErrand, name: String, x: Int, y: Int) -> Bool {
        guard !trip.isRehearsal else {
            return true
        }
        return trip.mover.place(name: name, x: x, y: y)
    }

    /// Leaves the icon at its final place and goes on to the next one.
    func settleIcon(trip: DesktopErrand, job: ErrandJob, now: TimeInterval) {
        // Give Finder the exact final place, trying twice
        var isPlaced = moveIcon(trip: trip, name: job.iconName, x: job.finalX, y: job.finalY)
        if !isPlaced && !trip.mover.wasRefused && !trip.mover.hasTimedOut {
            isPlaced = moveIcon(trip: trip, name: job.iconName, x: job.finalX, y: job.finalY)
        }
        guard isPlaced else {
            giveUpIcon(trip: trip, now: now)
            return
        }
        trip.movedCount += 1
        releaseIcon(trip: trip)
        advanceToNextJob(trip: trip, now: now)
    }

    /// Drops an icon Finder would not move, and ends the trip when Finder is out of reach.
    func giveUpIcon(trip: DesktopErrand, now: TimeInterval) {
        let wasRefused = trip.mover.wasRefused
        let isOutOfReach = wasRefused || trip.mover.hasTimedOut
        releaseIcon(trip: trip)
        guard isOutOfReach else {
            advanceToNextJob(trip: trip, now: now)
            return
        }
        cutErrandShort(now: now, dropsToFloor: true)
        if wasRefused {
            reportMischief(outcome: .notAllowed, successText: "", isUserRequest: trip.isUserRequest)
        }
    }

    /// Lets go of the icon in hand.
    func releaseIcon(trip: DesktopErrand) {
        trip.isHoldingIcon = false
        trip.isIconCovered = false
        trip.iconPanel?.hide()
        trip.iconPanel = nil
    }

    /// Heads for the next icon, or ends the trip after the last one.
    func advanceToNextJob(trip: DesktopErrand, now: TimeInterval) {
        trip.jobIndex += 1
        guard trip.currentJob != nil else {
            finishErrand(trip: trip, now: now)
            return
        }
        startApproach(trip: trip, now: now)
    }

    // MARK: - Ending

    /// Ends the trip after the last icon and says how it went.
    func finishErrand(trip: DesktopErrand, now: TimeInterval) {
        releaseIcon(trip: trip)
        lastErrandSummary = trip.summary
        errand = nil
        startFalling()
        guard !trip.isRehearsal else {
            lastMischiefReport = "rehearsal done: moved \(trip.movedCount) of \(trip.jobs.count) icons"
            return
        }
        switch trip.kind {
        case .mess:
            lastMischiefReport = "done: moved \(trip.movedCount) of \(trip.jobs.count) icons"
            let closingText = trip.movedCount > 0 ? "Hehe. I'll tidy up in a few minutes." : "Hmm, they would not budge."
            showTransientBubble(closingText, duration: 7, now: now)
        case .tidy:
            restoreDesktopAtOnce(isUserRequest: trip.isUserRequest)
        }
    }

    /// Ends the trip early: a mess is left for the tidy-up, a tidy-up is finished in one go.
    func cutErrandShort(now: TimeInterval, dropsToFloor: Bool) {
        guard let trip = errand else {
            return
        }
        releaseIcon(trip: trip)
        lastErrandSummary = trip.summary
        errand = nil
        if dropsToFloor {
            startFalling()
        }
        guard !trip.isRehearsal else {
            lastMischiefReport = "rehearsal cut short"
            return
        }
        switch trip.kind {
        case .mess:
            lastMischiefReport = "mess cut short after \(trip.movedCount) of \(trip.jobs.count) icons"
        case .tidy:
            restoreDesktopAtOnce(isUserRequest: trip.isUserRequest)
        }
    }

    // MARK: - Drawing

    /// Gives the room the carried icon takes above the head.
    var carriedIconHeadroom: CGFloat {
        guard let trip = errand, trip.isHoldingIcon else {
            return 0
        }
        return PetConfig.errandCarryGap + trip.iconSize + 6
    }

    /// Shows the copy of the carried icon wherever a window hides the real one.
    func placeCarriedIcon(now: TimeInterval) {
        guard let trip = errand, trip.isHoldingIcon else {
            return
        }

        // Refresh the list of windows now and then
        if now >= trip.nextWindowScanTime {
            trip.windowFrames = scanner.windowFrames()
            trip.nextWindowScanTime = now + PetConfig.errandWindowScanInterval
        }

        // Check whether a window covers the icon
        let iconRect = CGRect(
            x: trip.iconPoint.x - trip.iconSize / 2,
            y: trip.iconPoint.y - trip.iconSize / 2,
            width: trip.iconSize,
            height: trip.iconSize
        )
        trip.isIconCovered = trip.isRehearsal || trip.windowFrames.contains { $0.intersects(iconRect) }
        if trip.isIconCovered {
            trip.iconPanel?.show(iconCenter: trip.iconPoint, parent: panel)
        } else {
            trip.iconPanel?.hide()
        }
    }
}
