import AppKit

/// Moves the body: entrances, ledges, falls, walls and the ceiling.
extension PetController {
    // MARK: - Entrance

    /// Brings the pet onto the screen in one of several ways.
    func enterScreen() {
        let limits = screenFrame(near: NSEvent.mouseLocation)
        let randomX = CGFloat.random(in: (limits.minX + 80)...(limits.maxX - 80))
        support = nil
        switch Int.random(in: 0..<3) {
        case 0:
            // Drop from the top of the screen
            footPoint = CGPoint(x: randomX, y: limits.maxY - uprightSize.height - 10)
            velocity = .zero
        case 1:
            // Hop in from a bottom corner
            let entersFromLeft = Bool.random()
            let cornerX = entersFromLeft ? limits.minX + halfBodyWidth : limits.maxX - halfBodyWidth
            let hopDirection: CGFloat = entersFromLeft ? 1 : -1
            footPoint = CGPoint(x: cornerX, y: limits.minY + 4)
            velocity = CGVector(
                dx: hopDirection * CGFloat.random(in: 180...320),
                dy: CGFloat.random(in: 520...760)
            )
        default:
            // Pop up from below the bottom edge
            footPoint = CGPoint(x: randomX, y: limits.minY - uprightSize.height)
            velocity = CGVector(dx: 0, dy: CGFloat.random(in: 950...1200))
        }
        motion = .airborne
    }

    // MARK: - Step

    /// Moves the body according to what it is doing.
    func stepMotion(elapsed: TimeInterval, now: TimeInterval) {
        // Come down or wake up when Claude needs the stage
        if holdsStage {
            switch motion {
            case .climbing(let side, _):
                leaveWall(side: side)
            case .hanging:
                dropFromCeiling()
            case .sleeping:
                wakeUp(now: now, greets: false)
            case .standing, .walking, .airborne, .dragged, .roaming:
                break
            }
        }

        // Hold still while the cursor is on the activity board, except on a run across the desktop
        if isBoardHovered && !motion.isAirborne && !motion.isDragged && !motion.isRoaming {
            return
        }

        // Step the current motion
        switch motion {
        case .dragged, .sleeping:
            break
        case .airborne:
            stepAirborne(elapsed: CGFloat(elapsed), now: now)
        case .standing:
            stepStanding(now: now)
        case .walking(let direction):
            stepWalking(direction: direction, elapsed: CGFloat(elapsed), now: now)
        case .climbing(let side, let direction):
            stepClimbing(side: side, direction: direction, elapsed: CGFloat(elapsed), now: now)
        case .hanging(let direction):
            stepHanging(direction: direction, elapsed: CGFloat(elapsed), now: now)
        case .roaming:
            stepErrand(elapsed: CGFloat(elapsed), now: now)
        }
    }

    // MARK: - Ledges

    /// Keeps the pet on its ledge when the window under it moves.
    func followSupport(now: TimeInterval) {
        guard motion.isOnLedge else {
            return
        }
        guard let current = support else {
            startFalling()
            return
        }

        // Stay on the floor of the screen under the pet
        if current.isFloor {
            guard let floor = floorSurface(near: footPoint) else {
                return
            }
            footPoint.y = floor.height
            support = floor
            return
        }

        // Find the same window in the new scan
        let ledges = surfaces.filter { $0.windowNumber == current.windowNumber }
        guard let newFrame = ledges.first?.windowFrame, let oldFrame = current.windowFrame else {
            startFalling()
            return
        }

        // Ride along when the window moved
        var shiftX: CGFloat = 0
        if newFrame.size == oldFrame.size {
            shiftX = newFrame.minX - oldFrame.minX
        }
        if newFrame != oldFrame {
            rideBoostUntil = now + PetConfig.rideBoostDuration
        }
        footPoint.x += shiftX

        // Fall when the ledge no longer reaches the pet
        guard let ledge = ledges.first(where: { $0.contains(x: footPoint.x, tolerance: 2) }) else {
            startFalling()
            return
        }
        footPoint.y = ledge.height
        support = ledge
    }

    /// Lets go of the ledge.
    func startFalling() {
        motion = .airborne
        support = nil
        velocity = .zero
        clearPlan()
    }

    /// Forgets where the pet was heading.
    func clearPlan() {
        wantsToClimb = false
        climbTargetHeight = nil
        hangTargetX = nil
        idlePoseClipName = nil
    }

    /// Applies gravity and lands on the first ledge crossed on the way down.
    func stepAirborne(elapsed: CGFloat, now: TimeInterval) {
        // Apply gravity
        let previousSpeed = velocity.dy
        let previousHeight = footPoint.y
        velocity.dy = max(previousSpeed - PetConfig.gravity * elapsed, -PetConfig.maximumFallSpeed)
        footPoint.x += velocity.dx * elapsed
        footPoint.y += (previousSpeed + velocity.dy) / 2 * elapsed

        // Bounce off the sides of the screen
        let limits = screenFrame(near: footPoint)
        let minimumX = limits.minX + halfBodyWidth
        let maximumX = limits.maxX - halfBodyWidth
        if footPoint.x < minimumX {
            footPoint.x = minimumX
            velocity.dx = abs(velocity.dx) * PetConfig.wallBounce
        }
        if footPoint.x > maximumX {
            footPoint.x = maximumX
            velocity.dx = -abs(velocity.dx) * PetConfig.wallBounce
        }

        // Land on the highest ledge crossed during this step
        guard velocity.dy <= 0 else {
            return
        }
        let crossed = surfaces.filter { ledge in
            ledge.contains(x: footPoint.x) && ledge.height <= previousHeight && ledge.height >= footPoint.y
        }
        if let landing = crossed.max(by: { $0.height < $1.height }) {
            land(on: landing, now: now)
            return
        }

        // Stop at the floor
        if let floor = floorSurface(near: footPoint), footPoint.y <= floor.height {
            land(on: floor, now: now)
        }
    }

    /// Puts the pet down on a ledge.
    func land(on surface: Surface, now: TimeInterval) {
        footPoint.y = surface.height
        velocity = .zero
        support = surface
        motion = .standing
        clearPlan()
        actionDeadline = now + Double.random(in: 1.0...2.5)

        // Say hello after the first landing
        if !hasGreeted {
            hasGreeted = true
            playOnce("waving")
        }
    }

    /// Waits on the spot, then picks something to do.
    func stepStanding(now: TimeInterval) {
        // Hold still while Claude has the stage
        guard !holdsStage else {
            waveForAttentionIfDue(now: now)
            return
        }
        guard oneShotClipName == nil, now >= actionDeadline else {
            return
        }
        chooseNextAction(now: now)
    }

    /// Walks along the ledge and handles its ends.
    func stepWalking(direction: CGFloat, elapsed: CGFloat, now: TimeInterval) {
        // Stop when Claude needs the stage
        guard !holdsStage, oneShotClipName == nil else {
            motion = .standing
            clearPlan()
            return
        }
        guard let ledge = support else {
            startFalling()
            return
        }

        // Work out how far the ledge lets the pet go
        let inset = ledge.isFloor ? halfBodyWidth : 0
        let minimumX = ledge.minimumX + inset
        let maximumX = max(ledge.maximumX - inset, minimumX)
        footPoint.x = min(max(footPoint.x, minimumX), maximumX)
        let nextX = footPoint.x + direction * PetConfig.walkSpeed * elapsed

        // Stop before walking into the space around the cursor
        let isHeadingForCursor = (lastMouseLocation.x - footPoint.x) * direction > 0
        if isHeadingForCursor && isCursorNear(x: nextX, height: ledge.height) {
            standStill(now: now)
            return
        }

        // Keep walking while there is ledge ahead
        if nextX >= minimumX && nextX <= maximumX {
            footPoint.x = nextX
            if now >= actionDeadline && !wantsToClimb {
                standStill(now: now)
            }
            return
        }

        // Climb or turn at the side of the screen
        if ledge.isFloor {
            let side: WallSide = direction > 0 ? .right : .left
            let climbsByChance = Double.random(in: 0..<1) < PetConfig.climbChance
            if isClimbingEnabled && (wantsToClimb || climbsByChance) {
                startClimbing(side: side, now: now)
            } else {
                wantsToClimb = false
                motion = .walking(direction: -direction)
            }
            return
        }

        // Turn around or step off at the end of a window ledge
        if shouldStepOff(ledge: ledge, direction: direction) {
            footPoint.x = direction > 0 ? ledge.maximumX + 2 : ledge.minimumX - 2
            velocity = CGVector(dx: direction * PetConfig.walkSpeed, dy: 0)
            motion = .airborne
            support = nil
        } else {
            motion = .walking(direction: -direction)
        }
    }

    /// Decides whether to walk off the end of a window ledge.
    func shouldStepOff(ledge: Surface, direction: CGFloat) -> Bool {
        // Require open screen beyond the end of the ledge
        let limits = screenFrame(near: footPoint)
        let hasRoomRight = ledge.maximumX + 2 <= limits.maxX - halfBodyWidth
        let hasRoomLeft = ledge.minimumX - 2 >= limits.minX + halfBodyWidth
        let hasRoom = direction > 0 ? hasRoomRight : hasRoomLeft
        guard hasRoom else {
            return false
        }
        return Double.random(in: 0..<1) < PetConfig.stepOffChance
    }

    /// Leaps to a random ledge within reach.
    func jumpToAnotherLedge(onlyWindows: Bool) -> Bool {
        // List the landing ranges within reach
        let margin = halfBodyWidth
        var targets: [(ledge: Surface, range: ClosedRange<CGFloat>)] = []
        for ledge in surfaces {
            if let current = support, isSameLedge(ledge, current) {
                continue
            }
            if onlyWindows && ledge.isFloor {
                continue
            }
            let lower = max(ledge.minimumX + margin, footPoint.x - PetConfig.jumpReach)
            let upper = min(ledge.maximumX - margin, footPoint.x + PetConfig.jumpReach)
            if lower < upper {
                targets.append((ledge, lower...upper))
            }
        }
        // Pick a landing spot that keeps clear of the cursor
        for target in targets.shuffled() {
            for _ in 0..<PetConfig.landingSpotTries {
                let landingX = CGFloat.random(in: target.range)
                if !isCursorNear(x: landingX, height: target.ledge.height) {
                    jump(toHeight: target.ledge.height, landingX: landingX)
                    return true
                }
            }
        }
        return false
    }

    /// Launches an arc that comes down at a given point.
    func jump(toHeight landingHeight: CGFloat, landingX: CGFloat) {
        let apex = max(footPoint.y, landingHeight) + CGFloat.random(in: 50...110)
        let riseSpeed = sqrt(2 * PetConfig.gravity * (apex - footPoint.y))
        let riseTime = riseSpeed / PetConfig.gravity
        let fallTime = sqrt(2 * (apex - landingHeight) / PetConfig.gravity)
        clearPlan()
        velocity = CGVector(dx: (landingX - footPoint.x) / (riseTime + fallTime), dy: riseSpeed)
        motion = .airborne
        support = nil
    }

    /// Compares two ledges by window and position.
    func isSameLedge(_ first: Surface, _ second: Surface) -> Bool {
        return first.windowNumber == second.windowNumber
            && first.height == second.height
            && first.minimumX == second.minimumX
    }

    // MARK: - Walls

    /// Gives the distance from the wall contact point to either end of the turned body.
    var halfWallLength: CGFloat {
        return uprightSize.width / 2
    }

    /// Returns the x position of a wall of the screen being climbed.
    func wallX(side: WallSide) -> CGFloat {
        return side == .left ? climbLimits.minX : climbLimits.maxX
    }

    /// Returns the height of the floor at the foot of the screen being climbed.
    func climbFloorHeight() -> CGFloat {
        let insidePoint = CGPoint(x: climbLimits.midX, y: climbLimits.midY)
        return floorSurface(near: insidePoint)?.height ?? climbLimits.minY
    }

    /// Puts the pet on a side wall and sends it up.
    func startClimbing(side: WallSide, now: TimeInterval) {
        // Remember which screen is being climbed
        climbLimits = screenFrame(near: footPoint)
        let bottomHeight = climbFloorHeight() + halfWallLength
        let topHeight = climbLimits.maxY - halfWallLength

        // Pick how high to go
        clearPlan()
        if Bool.random() {
            climbTargetHeight = topHeight
        } else {
            let span = topHeight - bottomHeight
            climbTargetHeight = bottomHeight + span * CGFloat.random(in: 0.3...0.85)
        }

        // Stick to the wall
        footPoint = CGPoint(x: wallX(side: side), y: bottomHeight)
        velocity = .zero
        support = nil
        motion = .climbing(side: side, direction: 1)
    }

    /// Climbs, rests, and decides what to do at the ends of the wall.
    func stepClimbing(side: WallSide, direction: CGFloat, elapsed: CGFloat, now: TimeInterval) {
        // Follow the screen when its usable area changes
        climbLimits = screenFrame(near: CGPoint(x: climbLimits.midX, y: climbLimits.midY))
        let bottomHeight = climbFloorHeight() + halfWallLength
        let topHeight = climbLimits.maxY - halfWallLength
        footPoint.x = wallX(side: side)

        // Rest, then come down one way or the other
        if direction == 0 {
            guard now >= actionDeadline else {
                return
            }
            if Bool.random() {
                leaveWall(side: side)
            } else {
                motion = .climbing(side: side, direction: -1)
            }
            return
        }

        // Move along the wall
        footPoint.y += direction * PetConfig.climbSpeed * elapsed

        // Step back onto the floor at the bottom
        if direction < 0 {
            guard footPoint.y <= bottomHeight else {
                return
            }
            let inward: CGFloat = side == .left ? 1 : -1
            footPoint = CGPoint(x: wallX(side: side) + inward * halfBodyWidth, y: bottomHeight - halfWallLength)
            if let floor = floorSurface(near: footPoint) {
                land(on: floor, now: now)
            } else {
                startFalling()
            }
            return
        }

        // Keep going until the chosen height
        let targetHeight = min(climbTargetHeight ?? topHeight, topHeight)
        guard footPoint.y >= targetHeight else {
            return
        }
        footPoint.y = targetHeight

        // Rest part of the way up
        if targetHeight < topHeight - 0.5 {
            motion = .climbing(side: side, direction: 0)
            actionDeadline = now + Double.random(in: 1.5...3.5)
            return
        }

        // Cross to the ceiling or let go at the top
        if Double.random(in: 0..<1) < PetConfig.ceilingCrossChance {
            startHanging(from: side, now: now)
        } else {
            leaveWall(side: side)
        }
    }

    /// Jumps off a side wall.
    func leaveWall(side: WallSide) {
        // Turn the contact point into a spot for upright feet
        let inward: CGFloat = side == .left ? 1 : -1
        let size = uprightSize
        footPoint = CGPoint(x: footPoint.x + inward * size.height / 2, y: footPoint.y - size.height / 2)

        // Push away from the wall
        clearPlan()
        velocity = CGVector(
            dx: inward * CGFloat.random(in: 140...280),
            dy: CGFloat.random(in: 150...320)
        )
        motion = .airborne
        support = nil
    }

    /// Moves from the top of a wall to the underside of the ceiling.
    func startHanging(from side: WallSide, now: TimeInterval) {
        // Head away from the wall just climbed
        let direction: CGFloat = side == .left ? 1 : -1
        let minimumX = climbLimits.minX + halfWallLength
        let maximumX = climbLimits.maxX - halfWallLength
        let startX = side == .left ? minimumX : maximumX

        // Pick how far to go
        clearPlan()
        let farEnd = direction > 0 ? maximumX : minimumX
        let nearEnd = startX + direction * 150
        if (farEnd - nearEnd) * direction > 0 {
            hangTargetX = CGFloat.random(in: min(nearEnd, farEnd)...max(nearEnd, farEnd))
        } else {
            hangTargetX = farEnd
        }

        // Stick to the ceiling
        footPoint = CGPoint(x: startX, y: climbLimits.maxY)
        motion = .hanging(direction: direction)
    }

    /// Walks under the ceiling, then drops or heads down the far wall.
    func stepHanging(direction: CGFloat, elapsed: CGFloat, now: TimeInterval) {
        // Follow the screen when its usable area changes
        climbLimits = screenFrame(near: CGPoint(x: climbLimits.midX, y: climbLimits.midY))
        let minimumX = climbLimits.minX + halfWallLength
        let maximumX = climbLimits.maxX - halfWallLength
        footPoint.y = climbLimits.maxY

        // Rest, then drop
        if direction == 0 {
            guard now >= actionDeadline else {
                return
            }
            dropFromCeiling()
            return
        }

        // Move along the ceiling
        footPoint.x += direction * PetConfig.climbSpeed * elapsed

        // Go down the far wall or drop at the end of the ceiling
        if footPoint.x <= minimumX || footPoint.x >= maximumX {
            footPoint.x = min(max(footPoint.x, minimumX), maximumX)
            let side: WallSide = direction > 0 ? .right : .left
            if Bool.random() {
                footPoint = CGPoint(x: wallX(side: side), y: climbLimits.maxY - halfWallLength)
                motion = .climbing(side: side, direction: -1)
            } else {
                dropFromCeiling()
            }
            return
        }

        // Rest at the chosen spot
        if let targetX = hangTargetX, (targetX - footPoint.x) * direction <= 0 {
            hangTargetX = nil
            motion = .hanging(direction: 0)
            actionDeadline = now + Double.random(in: 1.0...2.5)
        }
    }

    /// Lets go of the ceiling.
    func dropFromCeiling() {
        footPoint = CGPoint(x: footPoint.x, y: footPoint.y - uprightSize.height)
        startFalling()
    }
}
