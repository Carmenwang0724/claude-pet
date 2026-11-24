import AppKit

/// Handles the mouse gestures, dropped files, the right-click menu and debug requests.
extension PetController: PetViewDelegate {
    // MARK: - Mouse

    func petViewDidBeginDrag(at location: CGPoint) {
        // Let go of a desktop trip
        cutErrandShort(now: CACurrentMediaTime(), dropsToFloor: false)

        // Hold the pet upright under the cursor when it comes off a wall or the ceiling
        if posture != .upright {
            footPoint = CGPoint(x: location.x, y: location.y - bodyHeight / 2)
        }

        // Pick the pet up
        grabOffset = CGSize(width: location.x - footPoint.x, height: location.y - footPoint.y)
        lastDragLocation = location
        motion = .dragged
        support = nil
        velocity = .zero
        clearPlan()
    }

    func petViewDidDrag(to location: CGPoint) {
        // Note which way the mouse is pulling
        let now = CACurrentMediaTime()
        let shiftX = location.x - lastDragLocation.x
        if abs(shiftX) >= PetConfig.dragTurnDistance {
            dragDirection = shiftX > 0 ? 1 : -1
            lastDragLocation = location
            lastDragMoveTime = now
        }

        // Follow the mouse
        footPoint = CGPoint(x: location.x - grabOffset.width, y: location.y - grabOffset.height)
        placeWindows(now: now)
    }

    func petViewDidEndDrag(velocity releaseVelocity: CGVector) {
        let now = CACurrentMediaTime()
        let speed = hypot(releaseVelocity.dx, releaseVelocity.dy)

        // Put the pet back on the floor when it is released below it
        if let floor = floorSurface(near: footPoint), footPoint.y <= floor.height {
            land(on: floor, now: now)
            return
        }

        // Set the pet down on a ledge right under a gentle release
        if speed < 200 {
            let nearbyLedge = surfaces.first { ledge in
                ledge.contains(x: footPoint.x) && abs(ledge.height - footPoint.y) <= 14
            }
            if let nearbyLedge = nearbyLedge {
                land(on: nearbyLedge, now: now)
                return
            }
        }

        // Throw the pet with the speed of the mouse
        let limit = PetConfig.maximumThrowSpeed
        let scale = speed > limit ? limit / speed : 1
        velocity = CGVector(dx: releaseVelocity.dx * scale, dy: releaseVelocity.dy * scale)
        motion = .airborne
    }

    func petViewWasClicked() {
        // Open the session that needs attention most, or just bring Claude forward
        monitor.acknowledgeReviews()
        if !openMostUrgentActivity() {
            activateClaude()
        }
        pendingClaudeJumpTime = CACurrentMediaTime() + PetConfig.claudeJumpDelay
    }

    func petViewDidReceiveFiles(_ fileURLs: [URL]) {
        // Put the file paths on the clipboard
        let paths = fileURLs.map { $0.path }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)

        // Hand over to Claude
        let now = CACurrentMediaTime()
        activateClaude()
        playOnce("jumping")
        let copiedText = paths.count == 1 ? "Path copied" : "\(paths.count) paths copied"
        showTransientBubble("\(copiedText). Paste it in Claude.", duration: 6, now: now)
    }

    // MARK: - Menu

    func petViewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Show the pet name
        let titleItem = NSMenuItem(title: atlas.displayName, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(makeItem(title: "Open Claude", action: #selector(openClaude(_:))))
        menu.addItem(NSMenuItem.separator())

        // List the installed pets
        let petMenu = NSMenu()
        for listing in PetLibrary.installedPets() {
            let item = makeItem(title: listing.displayName, action: #selector(selectPet(_:)))
            item.representedObject = listing.identifier
            item.state = listing.identifier == atlas.identifier ? .on : .off
            petMenu.addItem(item)
        }
        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        petItem.submenu = petMenu
        menu.addItem(petItem)

        // List the sizes
        let sizeMenu = NSMenu()
        for index in 0..<PetConfig.displayScaleValues.count {
            let value = PetConfig.displayScaleValues[index]
            let item = makeItem(title: PetConfig.displayScaleTitles[index], action: #selector(selectScale(_:)))
            item.representedObject = value
            item.state = abs(Double(displayScale) - value) < 0.001 ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(NSMenuItem.separator())

        // Add the behaviour switches
        menu.addItem(makeSwitch(title: "Stay Put", isOn: isWanderingPaused, action: #selector(toggleWandering(_:))))
        menu.addItem(makeSwitch(title: "Climb Walls and Ceiling", isOn: isClimbingEnabled, action: #selector(toggleClimbing(_:))))
        menu.addItem(makeSwitch(title: "React to the Mouse", isOn: isMousePlayEnabled, action: #selector(toggleMousePlay(_:))))
        menu.addItem(makeSwitch(title: "Break and Bedtime Reminders", isOn: areRemindersEnabled, action: #selector(toggleReminders(_:))))
        menu.addItem(makeSwitch(title: "Pin Task List to Top Right", isOn: isBoardPinned, action: #selector(toggleBoardPin(_:))))
        let swapsRunningRows = PetPreferences.swapsRunningRows(identifier: atlas.identifier)
        menu.addItem(makeSwitch(title: "Swap Left and Right Walk", isOn: swapsRunningRows, action: #selector(toggleRunningRowSwap(_:))))
        menu.addItem(NSMenuItem.separator())

        // Add the desktop teasing
        let isFreeForTrip = errand == nil && !mischief.isBusy
        let messItem = makeItem(title: "Mess Up the Desktop", action: #selector(makeDesktopMess(_:)))
        messItem.isEnabled = isFreeForTrip
        menu.addItem(messItem)
        let tidyItem = makeItem(title: "Tidy the Desktop", action: #selector(tidyDesktop(_:)))
        tidyItem.isEnabled = isFreeForTrip && mischief.hasSnapshot
        menu.addItem(tidyItem)
        menu.addItem(makeSwitch(title: "Visit the Desktop on Her Own", isOn: isAutoMischiefEnabled, action: #selector(toggleAutoMischief(_:))))
        menu.addItem(NSMenuItem.separator())

        // Add the housekeeping
        menu.addItem(makeItem(title: "Clear Task List", action: #selector(clearAgentState(_:))))
        menu.addItem(makeItem(title: "Quit", action: #selector(quit(_:))))
        return menu
    }

    /// Builds a menu item that calls back into this controller.
    func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Builds a menu item with a check mark.
    func makeSwitch(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = makeItem(title: title, action: action)
        item.state = isOn ? .on : .off
        return item
    }

    @objc func openClaude(_ sender: NSMenuItem) {
        activateClaude()
    }

    @objc func selectPet(_ sender: NSMenuItem) {
        // Find the chosen pet
        guard let identifier = sender.representedObject as? String else {
            return
        }
        guard let listing = PetLibrary.listing(identifier: identifier) else {
            return
        }

        // Load it and remember the choice
        guard showPet(listing: listing) else {
            return
        }
        UserDefaults.standard.set(identifier, forKey: PetConfig.selectedPetKey)
    }

    @objc func selectScale(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else {
            return
        }
        displayScale = CGFloat(value)
        UserDefaults.standard.set(value, forKey: PetConfig.displayScaleKey)
    }

    @objc func toggleWandering(_ sender: NSMenuItem) {
        isWanderingPaused.toggle()
        UserDefaults.standard.set(isWanderingPaused, forKey: PetConfig.wanderingPausedKey)
    }

    @objc func toggleClimbing(_ sender: NSMenuItem) {
        isClimbingEnabled.toggle()
        UserDefaults.standard.set(isClimbingEnabled, forKey: PetConfig.climbingEnabledKey)
    }

    @objc func toggleMousePlay(_ sender: NSMenuItem) {
        isMousePlayEnabled.toggle()
        UserDefaults.standard.set(isMousePlayEnabled, forKey: PetConfig.mousePlayEnabledKey)
    }

    @objc func toggleReminders(_ sender: NSMenuItem) {
        areRemindersEnabled.toggle()
        UserDefaults.standard.set(areRemindersEnabled, forKey: PetConfig.remindersEnabledKey)
    }

    @objc func toggleBoardPin(_ sender: NSMenuItem) {
        isBoardPinned.toggle()
        UserDefaults.standard.set(isBoardPinned, forKey: PetConfig.boardPinnedKey)
    }

    @objc func toggleAutoMischief(_ sender: NSMenuItem) {
        isAutoMischiefEnabled.toggle()
        UserDefaults.standard.set(isAutoMischiefEnabled, forKey: PetConfig.autoMischiefEnabledKey)
        nextMischiefTime = CACurrentMediaTime() + randomMischiefGap()
    }

    @objc func toggleRunningRowSwap(_ sender: NSMenuItem) {
        // Flip the saved choice for the current pet
        let identifier = atlas.identifier
        let swapsRunningRows = !PetPreferences.swapsRunningRows(identifier: identifier)
        PetPreferences.setSwapsRunningRows(swapsRunningRows, identifier: identifier)

        // Cut the atlas again
        guard let listing = PetLibrary.listing(identifier: identifier) else {
            return
        }
        _ = showPet(listing: listing)
    }

    @objc func makeDesktopMess(_ sender: NSMenuItem) {
        startMischief(iconCount: PetConfig.mischiefIconCount, isUserRequest: true, now: CACurrentMediaTime())
    }

    @objc func tidyDesktop(_ sender: NSMenuItem) {
        startTidy(isUserRequest: true, now: CACurrentMediaTime())
    }

    @objc func clearAgentState(_ sender: NSMenuItem) {
        monitor.clearAll()
    }

    @objc func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    /// Loads a pet with its saved options and shows it.
    func showPet(listing: PetListing) -> Bool {
        let swapsRunningRows = PetPreferences.swapsRunningRows(identifier: listing.identifier)
        let loadedAtlas = autoreleasepool {
            try? PetAtlas.load(folder: listing.folder, swapsRunningRows: swapsRunningRows)
        }
        guard let newAtlas = loadedAtlas else {
            NSSound.beep()
            return false
        }
        atlas = newAtlas
        shownClipName = ""
        shownFrameIndex = -1
        player = AnimationPlayer()
        perform(#selector(releaseUnusedMemory), with: nil, afterDelay: PetConfig.memoryReliefDelay)
        return true
    }

    // MARK: - Debug

    /// Runs the command in the debug request file, then writes the current state to a file.
    func answerDebugRequest(now: TimeInterval) {
        // Read and remove the request
        let requestURL = PetConfig.debugRequestFile
        guard let commandText = try? String(contentsOf: requestURL, encoding: .utf8) else {
            return
        }
        try? FileManager.default.removeItem(at: requestURL)

        // Run the command
        let words = commandText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        runDebugCommand(words: words, now: now)

        // Describe the ledges
        let ledgeReports: [[String: Any]] = surfaces.map { ledge in
            [
                "window": ledge.windowNumber.map { Int($0) } ?? -1,
                "owner": ledge.ownerProcess.map { Int($0) } ?? -1,
                "height": Double(ledge.height),
                "minimumX": Double(ledge.minimumX),
                "maximumX": Double(ledge.maximumX),
            ]
        }

        // Describe the activity board
        let activityReports: [[String: Any]] = activities.map { activity in
            [
                "title": activity.title,
                "status": activity.status.name,
                "host": activity.hostSessionIdentifier ?? "",
                "since": activity.since,
            ]
        }
        let rowReports = boardRows.map { row in
            "\(ActivityBoardView.statusText(for: row.status)) | \(row.title) | \(row.timeText)"
        }

        // Describe the pet
        let report: [String: Any] = [
            "activities": activityReports,
            "boardRows": rowReports,
            "isBoardHovered": isBoardHovered,
            "boardFrame": NSStringFromRect(board.visibleFrame),
            "lastOpenedLink": lastOpenedLink,
            "pet": atlas.identifier,
            "motion": motion.name,
            "posture": posture.name,
            "footX": Double(footPoint.x),
            "footY": Double(footPoint.y),
            "supportWindow": support?.windowNumber.map { Int($0) } ?? -1,
            "supportIsFloor": support?.isFloor ?? false,
            "clip": shownClipName,
            "frame": shownFrameIndex,
            "agentState": agent.state.rawValue,
            "agentLabel": agent.label ?? "",
            "bubble": bubbleText ?? "",
            "displayScale": Double(displayScale),
            "panelFrame": NSStringFromRect(panel.frame),
            "ignoresMouse": panel.ignoresMouseEvents,
            "idleSeconds": idleSeconds(),
            "mischief": lastMischiefReport,
            "isVisitingCursor": isVisitingCursor,
            "wantsToClimb": wantsToClimb,
            "mischiefBusy": mischief.isBusy,
            "errand": errand?.summary ?? "",
            "lastErrand": lastErrandSummary,
            "autoTidyIn": autoTidyTime.map { $0 - now } ?? -1,
            "curtainHiddenApps": curtain.hiddenCount,
            "desktopCoverage": Double(desktopCoverage()),
            "hasDesktopSnapshot": mischief.hasSnapshot,
            "ledges": ledgeReports,
            "sessions": monitor.debugReport(),
        ]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: options) else {
            return
        }
        try? data.write(to: PetConfig.debugOutputFile)
    }

    /// Carries out one debug command.
    func runDebugCommand(words: [String], now: TimeInterval) {
        guard let command = words.first else {
            return
        }
        switch command {
        case "jump":
            _ = jumpToAnotherLedge(onlyWindows: false)
        case "drop":
            if words.count == 3, let dropX = Double(words[1]), let dropY = Double(words[2]) {
                footPoint = CGPoint(x: dropX, y: dropY)
                startFalling()
            }
        case "walk":
            if words.count == 2 {
                clearPlan()
                motion = .walking(direction: words[1] == "left" ? -1 : 1)
                actionDeadline = now + 30
            }
        case "climb":
            if words.count == 2, motion.isAwakeOnLedge {
                startClimbing(side: words[1] == "left" ? .left : .right, now: now)
            }
        case "enter":
            enterScreen()
        case "snapshot":
            if words.count == 2, let image = petView.renderSnapshot(scale: 2) {
                _ = ImageFile.writePNG(image: image, to: URL(fileURLWithPath: words[1]))
            }
        case "sleep":
            settleToSleep()
        case "awake":
            if words.count == 2, let seconds = Double(words[1]) {
                sleepBlockedUntil = now + seconds
                if motion.isSleeping {
                    wakeUp(now: now, greets: false)
                }
            }
        case "remind":
            remindBreak(now: now)
        case "night":
            showNightNudge(now: now)
        case "click":
            petViewWasClicked()
        case "board-click":
            if words.count >= 2, let index = Int(words[1]) {
                isLinkOpeningDisabled = words.count == 3 && words[2] == "dry"
                openActivity(at: index)
                isLinkOpeningDisabled = false
            }
        case "snapshot-board":
            if words.count == 2, let image = board.renderSnapshot(scale: 2) {
                _ = ImageFile.writePNG(image: image, to: URL(fileURLWithPath: words[1]))
            }
        case "mouse":
            if words.count == 2 {
                simulatedMousePath = makeMousePath(kind: words[1])
            }
        case "desktop-probe":
            mischief.probe { [weak self] outcome in
                self?.reportMischief(outcome: outcome, successText: "Desktop checked", isUserRequest: false)
            }
        case "desktop-mess":
            let iconCount = words.count == 2 ? Int(words[1]) ?? PetConfig.mischiefIconCount : PetConfig.mischiefIconCount
            startMischief(iconCount: iconCount, isUserRequest: true, now: now)
        case "desktop-tidy":
            startTidy(isUserRequest: true, now: now)
        case "snapshot-icon":
            if words.count == 2, let image = CarriedIconPanel.renderSample(fileName: "Rehearsal notes.pdf", iconSize: mischief.desktopIconSize) {
                _ = ImageFile.writePNG(image: image, to: URL(fileURLWithPath: words[1]))
            }
        case "curtain-open":
            openCurtain()
        case "curtain-close":
            closeCurtain()
        case "desktop-rehearse":
            rehearseErrand(now: now)
        case "desktop-restore":
            restoreDesktopAtOnce(isUserRequest: true)
        default:
            break
        }
    }

    /// Builds a scripted cursor path around the pet, one point per step.
    func makeMousePath(kind: String) -> [CGPoint] {
        let headHeight = footPoint.y + bodyHeight * 0.8
        let middleHeight = footPoint.y + bodyHeight / 2
        var path: [CGPoint] = []
        switch kind {
        case "rush":
            // Hold still far away, then rush at the body
            for _ in 0..<10 {
                path.append(CGPoint(x: footPoint.x + 700, y: middleHeight))
            }
            for step in 1...7 {
                path.append(CGPoint(x: footPoint.x + 700 - CGFloat(step) * 95, y: middleHeight))
            }
        case "pet":
            // Rub left and right over the head
            for step in 0..<60 {
                let phase = CGFloat(step % 12)
                let offset = phase < 6 ? phase * 8 - 24 : (12 - phase) * 8 - 24
                path.append(CGPoint(x: footPoint.x + offset, y: headHeight))
            }
        case "rest":
            // Arrive beside the pet and stay there
            for step in 0..<400 {
                let settleShift: CGFloat = step < 3 ? CGFloat(3 - step) * 10 : 0
                path.append(CGPoint(x: footPoint.x + 320 + settleShift, y: middleHeight))
            }
        default:
            break
        }
        return path
    }
}
