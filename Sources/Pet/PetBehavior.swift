import AppKit

/// Decides what the pet does on its own, and how it reacts to the mouse and the clock.
extension PetController {
    // MARK: - Choosing

    /// Picks the next thing to do while nothing needs the stage.
    func chooseNextAction(now: TimeInterval) {
        // Stay put when wandering is paused
        guard !isWanderingPaused else {
            standStill(now: now)
            return
        }

        // Walk over to a mouse cursor that has just come to rest
        let wantsCursorVisit = Double.random(in: 0..<1) < PetConfig.cursorVisitChance
        if wantsCursorVisit, let visitX = cursorVisitTarget(now: now) {
            startWalking(toward: visitX, now: now)
            isVisitingCursor = true
            visitedCursorRestSince = mouseStillSince
            return
        }

        // Hop to a window now and then when one is within reach
        let wantsWindowJump = Double.random(in: 0..<1) < PetConfig.windowJumpChance
        if wantsWindowJump && jumpToAnotherLedge(onlyWindows: true) {
            return
        }

        // Head for a side of the screen to climb it
        let isOnFloor = support?.isFloor ?? false
        let wantsClimbTrip = Double.random(in: 0..<1) < PetConfig.climbTripChance
        if isClimbingEnabled && isOnFloor && wantsClimbTrip {
            startClimbTrip(now: now)
            return
        }

        // Roll for an everyday action
        let roll = Double.random(in: 0..<1)
        if roll < 0.62 {
            standStill(now: now)
        } else if roll < 0.76 {
            startWalking(now: now)
        } else if roll < 0.92 {
            strikePose(now: now)
        } else if roll < 0.95 {
            playOnce("jumping")
            standStill(now: now)
        } else if !jumpToAnotherLedge(onlyWindows: false) {
            standStill(now: now)
        }
    }

    /// Stands for a few seconds.
    func standStill(now: TimeInterval) {
        motion = .standing
        clearPlan()
        actionDeadline = now + Double.random(in: 6...16)
    }

    /// Holds one of the spare poses for a few seconds.
    func strikePose(now: TimeInterval) {
        motion = .standing
        clearPlan()

        // Read the book more often while Claude is working
        let isWorking = agent.state == .running
        if isWorking && Double.random(in: 0..<1) < PetConfig.workingPoseChance {
            idlePoseClipName = "running"
        } else {
            idlePoseClipName = PetConfig.idlePoseClips.randomElement()
        }
        actionDeadline = now + Double.random(in: 3...6)
    }

    /// Walks for a few seconds, away from a nearby ledge end.
    func startWalking(now: TimeInterval) {
        var direction: CGFloat = Bool.random() ? 1 : -1
        if let ledge = support {
            if footPoint.x - ledge.minimumX < 80 {
                direction = 1
            }
            if ledge.maximumX - footPoint.x < 80 {
                direction = -1
            }
        }
        clearPlan()
        motion = .walking(direction: direction)
        actionDeadline = now + Double.random(in: 2...5)
    }

    /// Walks to a given spot on the current ledge.
    func startWalking(toward targetX: CGFloat, now: TimeInterval) {
        clearPlan()
        walkTargetX = targetX
        motion = .walking(direction: targetX > footPoint.x ? 1 : -1)
        actionDeadline = now + 60
    }

    /// Walks to a side of the screen in order to climb it.
    func startClimbTrip(now: TimeInterval) {
        // Prefer the nearer side
        let limits = screenFrame(near: footPoint)
        let isOnRightHalf = footPoint.x > limits.midX
        let prefersNearSide = Double.random(in: 0..<1) < 0.7
        let headsRight = isOnRightHalf == prefersNearSide

        // Walk until the wall
        clearPlan()
        wantsToClimb = true
        motion = .walking(direction: headsRight ? 1 : -1)
        actionDeadline = now + 120
    }

    // MARK: - Mouse

    /// Finds a spot next to a resting cursor that the pet can walk to.
    func cursorVisitTarget(now: TimeInterval) -> CGFloat? {
        guard isMousePlayEnabled, let ledge = support else {
            return nil
        }

        // Visit each rest of the cursor once, shortly after it began
        let restTime = now - mouseStillSince
        guard restTime >= PetConfig.cursorRestTime, restTime <= 20 else {
            return nil
        }
        guard mouseStillSince != visitedCursorRestSince else {
            return nil
        }

        // Require the cursor to be near the pet's level and a walk away
        let mouse = lastMouseLocation
        let distance = mouse.x - footPoint.x
        guard abs(distance) >= PetConfig.cursorVisitGap * 2, abs(distance) <= PetConfig.cursorVisitReach else {
            return nil
        }
        guard mouse.y >= ledge.height - 60, mouse.y <= ledge.height + bodyHeight + 260 else {
            return nil
        }

        // Stop a little short of the cursor
        let stopX = mouse.x - (distance > 0 ? 1 : -1) * PetConfig.cursorVisitGap
        guard ledge.contains(x: stopX) else {
            return nil
        }
        return stopX
    }

    /// Follows the cursor and triggers the reactions to it.
    func trackMouse(now: TimeInterval) {
        // Measure how the cursor moved since the last step
        let mouse = simulatedMousePath.isEmpty ? NSEvent.mouseLocation : simulatedMousePath.removeFirst()
        let previousMouse = lastMouseLocation
        let interval = CGFloat(now - lastMouseSampleTime)
        if interval > 0 {
            let rawVelocityX = (mouse.x - previousMouse.x) / interval
            let rawVelocityY = (mouse.y - previousMouse.y) / interval
            mouseVelocity = CGVector(
                dx: mouseVelocity.dx * 0.5 + rawVelocityX * 0.5,
                dy: mouseVelocity.dy * 0.5 + rawVelocityY * 0.5
            )
        }
        if hypot(mouse.x - previousMouse.x, mouse.y - previousMouse.y) > 2 {
            mouseStillSince = now
        }
        lastMouseLocation = mouse
        lastMouseSampleTime = now

        // React only while standing or walking with nothing else going on
        let canPlay = isMousePlayEnabled && motion.isAwakeOnLedge && !holdsStage && !petView.isTrackingPress
        guard canPlay else {
            resetPetting()
            return
        }
        if detectPetting(mouse: mouse, previousMouse: previousMouse, now: now) {
            return
        }
        detectStartle(mouse: mouse, now: now)
    }

    /// Notices the cursor rubbing back and forth over the head and returns whether it is there.
    func detectPetting(mouse: CGPoint, previousMouse: CGPoint, now: TimeInterval) -> Bool {
        // Outline the head
        let headRect = CGRect(
            x: footPoint.x - halfBodyWidth * 1.1,
            y: footPoint.y + bodyHeight * 0.5,
            width: halfBodyWidth * 2.2,
            height: bodyHeight * 0.55
        )
        guard headRect.contains(mouse) else {
            if now - pettingLastInsideTime > 0.5 {
                resetPetting()
            }
            return false
        }
        pettingLastInsideTime = now

        // Add up the sideways strokes
        let shiftX = mouse.x - previousMouse.x
        if abs(shiftX) > 0.5 {
            let direction: CGFloat = shiftX > 0 ? 1 : -1
            if pettingDirection != 0 && direction != pettingDirection {
                pettingReversals += 1
            }
            pettingDirection = direction
            pettingTravel += abs(shiftX)
        }

        // Enjoy it once there have been enough strokes
        let hasEnoughStrokes = pettingTravel >= PetConfig.pettingTravel && pettingReversals >= PetConfig.pettingReversals
        if hasEnoughStrokes && now >= pettingCooldownUntil {
            resetPetting()
            pettingCooldownUntil = now + PetConfig.pettingCooldown
            motion = .standing
            clearPlan()
            actionDeadline = now + 2
            playOnce("jumping")
            showTransientBubble("Hehe", duration: 2, now: now)
        }
        return true
    }

    /// Forgets the strokes counted so far.
    func resetPetting() {
        pettingTravel = 0
        pettingReversals = 0
        pettingDirection = 0
    }

    /// Jumps away when the cursor rushes at the pet.
    func detectStartle(mouse: CGPoint, now: TimeInterval) {
        guard now >= startleCooldownUntil else {
            return
        }
        let boardNeedsClick = activities.contains { $0.status != .running }
        guard !boardNeedsClick, !isBoardHovered else {
            return
        }
        let speed = hypot(mouseVelocity.dx, mouseVelocity.dy)
        guard speed >= PetConfig.startleMouseSpeed else {
            return
        }

        // Check that the cursor is close and heading for the body
        let towardPetX = footPoint.x - mouse.x
        let towardPetY = footPoint.y + bodyHeight / 2 - mouse.y
        let distance = hypot(towardPetX, towardPetY)
        guard distance <= PetConfig.startleDistance, distance > 20 else {
            return
        }
        let alignment = (mouseVelocity.dx * towardPetX + mouseVelocity.dy * towardPetY) / (speed * distance)
        guard alignment > 0.6 else {
            return
        }

        // Jump away from the cursor
        let awayDirection: CGFloat = towardPetX >= 0 ? 1 : -1
        clearPlan()
        velocity = CGVector(dx: awayDirection * 420, dy: 560)
        motion = .airborne
        support = nil
        startleCooldownUntil = now + PetConfig.startleCooldown
        showTransientBubble("Whoa!", duration: 1.2, now: now)
    }

    // MARK: - Rhythm

    /// Reports how long the keyboard and mouse have been untouched.
    func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else {
            return 0
        }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Checks once a second whether to sleep, wake, remind or tease.
    func trackActivityIfDue(now: TimeInterval) {
        guard now >= nextActivityCheckTime else {
            return
        }
        nextActivityCheckTime = now + PetConfig.activityCheckInterval
        let idleTime = idleSeconds()

        // Sleep while the computer is left alone
        let maySleep = !holdsStage && now >= sleepBlockedUntil
        if idleTime >= PetConfig.sleepAfterIdle && maySleep {
            settleToSleep()
        } else if motion.isSleeping && idleTime < PetConfig.wakeIdleLimit {
            wakeUp(now: now, greets: true)
        }

        // Follow the working rhythm
        if areRemindersEnabled {
            trackWorkStretch(idleTime: idleTime, now: now)
            nudgeAtNight(idleTime: idleTime, now: now)
        }

        // Visit the desktop now and then while the user is around to watch
        let isFreeForTrip = !holdsStage && errand == nil && !mischief.isBusy
        let userIsAround = idleTime < PetConfig.awayIdleTime
        let wantsVisit = isAutoMischiefEnabled && !isWanderingPaused && !mischief.hasSnapshot
        if wantsVisit && isFreeForTrip && userIsAround && motion.isAwakeOnLedge && now >= nextMischiefTime {
            nextMischiefTime = now + randomMischiefGap()
            if desktopCoverage() < PetConfig.visibleDesktopCoverageLimit {
                startMischief(iconCount: PetConfig.autoMischiefIconCount, isUserRequest: false, now: now)
            } else {
                lastMischiefReport = "visit skipped: windows hide the desktop"
            }
        }

        // Tidy up a few minutes after a mess
        let canSetOff = motion.isAwakeOnLedge || motion.isSleeping
        if let tidyTime = autoTidyTime, now >= tidyTime, isFreeForTrip, canSetOff {
            startTidy(isUserRequest: false, now: now)
        }
    }

    /// Lies down on the current ledge, coming down from a wall first.
    func settleToSleep() {
        switch motion {
        case .standing, .walking:
            motion = .sleeping
            clearPlan()
            oneShotClipName = nil
        case .climbing(let side, _):
            leaveWall(side: side)
        case .hanging:
            dropFromCeiling()
        case .airborne, .dragged, .sleeping, .roaming:
            break
        }
    }

    /// Gets up, with a greeting when the user is back.
    func wakeUp(now: TimeInterval, greets: Bool) {
        motion = .standing
        actionDeadline = now + 1.5
        if greets {
            playOnce("waving")
            showTransientBubble("Welcome back", duration: 3, now: now)
        }
    }

    /// Reminds the user to take a break after a long unbroken stretch.
    func trackWorkStretch(idleTime: TimeInterval, now: TimeInterval) {
        // Restart the count after a real break
        if idleTime >= PetConfig.breakIdleTime {
            workStartedAt = nil
            return
        }
        guard idleTime < 60 else {
            return
        }
        guard let startedAt = workStartedAt else {
            workStartedAt = now
            return
        }
        guard now - startedAt >= PetConfig.workStretch else {
            return
        }
        workStartedAt = now
        remindBreak(now: now)
    }

    /// Shows the break reminder.
    func remindBreak(now: TimeInterval) {
        playOnce("waving")
        showTransientBubble("50 minutes straight. Time to stretch.", duration: 12, now: now)
    }

    /// Suggests going to bed in the small hours.
    func nudgeAtNight(idleTime: TimeInterval, now: TimeInterval) {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < PetConfig.nightEndHour, idleTime < 60 else {
            return
        }
        guard now - lastNightNudgeAt >= PetConfig.nightNudgeInterval else {
            return
        }
        lastNightNudgeAt = now
        showNightNudge(now: now)
    }

    /// Shows the bedtime message.
    func showNightNudge(now: TimeInterval) {
        playOnce("waving")
        showTransientBubble("It's late. Get some sleep.", duration: 10, now: now)
    }
}
