import AppKit

/// Connects the pet to what the Claude sessions are doing.
extension PetController {
    // MARK: - Polling

    /// Reads new hook events a few times per second.
    func pollAgentIfDue(now: TimeInterval) {
        guard now >= nextEventPollTime else {
            return
        }
        nextEventPollTime = now + PetConfig.eventPollInterval

        // Read the new events
        let wallClock = Date().timeIntervalSince1970
        let moments = monitor.poll()
        let previous = agent
        agent = monitor.summary(now: wallClock)
        activities = monitor.activities(now: wallClock)
        boardRows = makeBoardRows(wallClock: wallClock)

        // React to a change of state
        if agent != previous {
            reactToAgentChange(from: previous, now: now)
        }
        for moment in moments {
            react(to: moment)
        }

        // Answer a pending debug request
        answerDebugRequest(now: now)
    }

    /// Updates the pose when Claude moves to another state.
    func reactToAgentChange(from previous: AgentSummary, now: TimeInterval) {
        idlePoseClipName = nil
        nextAttentionWaveTime = now + PetConfig.attentionWaveInterval

        // Open the book for a moment when Claude starts working
        let hasStartedWorking = agent.state == .running && previous.state != .running
        if hasStartedWorking && motion.isAwakeOnLedge {
            motion = .standing
            clearPlan()
            idlePoseClipName = "running"
            actionDeadline = now + PetConfig.workingPoseDuration
        }
    }

    /// Plays the reaction to a one-time event.
    func react(to moment: AgentMoment) {
        switch moment {
        case .sessionStarted:
            playOnce("waving")
        case .turnFinished:
            playOnce("jumping")
        case .turnFailed:
            playOnce("failed")
        }
    }

    /// Waves every few seconds while Claude is waiting for the user.
    func waveForAttentionIfDue(now: TimeInterval) {
        let isWaiting = agent.state == .waitingForPermission || agent.state == .waitingForAnswer
        guard isWaiting, oneShotClipName == nil, now >= nextAttentionWaveTime else {
            return
        }
        nextAttentionWaveTime = now + PetConfig.attentionWaveInterval
        playOnce("waving")
    }

    // MARK: - Board

    /// Turns the session list into the rows of the activity board.
    func makeBoardRows(wallClock: TimeInterval) -> [BoardRow] {
        // Leave room for a last row that counts the rest
        let limit = PetConfig.boardRowLimit
        let hasOverflow = activities.count > limit
        let shownActivities = hasOverflow ? Array(activities.prefix(limit - 1)) : activities

        // Describe each session
        var rows: [BoardRow] = []
        for activity in shownActivities {
            rows.append(
                BoardRow(
                    status: activity.status,
                    title: shortTitle(activity.title),
                    timeText: timeText(for: activity, wallClock: wallClock)
                )
            )
        }
        if hasOverflow {
            let hiddenCount = activities.count - shownActivities.count
            rows.append(BoardRow(status: nil, title: "+\(hiddenCount) more", timeText: ""))
        }
        return rows
    }

    /// Cuts a long session title down to fit a row, counting wide characters twice.
    func shortTitle(_ title: String) -> String {
        var usedWidth = 0
        var kept = ""
        for character in title {
            let characterWidth = character.isASCII ? 1 : 2
            guard usedWidth + characterWidth <= PetConfig.boardTitleWidth else {
                return kept + "…"
            }
            usedWidth += characterWidth
            kept.append(character)
        }
        return kept
    }

    /// Says how long a session has been in its current state.
    func timeText(for activity: SessionActivity, wallClock: TimeInterval) -> String {
        // Round the duration down to minutes or hours
        let seconds = max(0, wallClock - activity.since)
        let minutes = Int(seconds / 60)
        var durationText = "now"
        if minutes >= 60 {
            durationText = "\(minutes / 60) h"
        } else if minutes >= 1 {
            durationText = "\(minutes) min"
        }

        // Finished and failed turns count back from now
        let countsBack = activity.status == .ready || activity.status == .blocked
        if countsBack && minutes >= 1 {
            return durationText + " ago"
        }
        return durationText
    }

    /// Opens the session of a clicked board row.
    func openActivity(at index: Int) {
        guard index >= 0, index < boardRows.count else {
            return
        }

        // The last row may only count the sessions that did not fit
        guard index < activities.count, boardRows[index].status != nil else {
            activateClaude()
            return
        }

        // Mark the session as seen and go to it
        let activity = activities[index]
        monitor.acknowledge(sessionIdentifier: activity.sessionIdentifier)
        openSession(hostSessionIdentifier: activity.hostSessionIdentifier)
        nextEventPollTime = 0
    }

    /// Opens the session that needs attention most and reports whether there was one.
    func openMostUrgentActivity() -> Bool {
        guard let activity = activities.first, activity.status != .running else {
            return false
        }
        monitor.acknowledge(sessionIdentifier: activity.sessionIdentifier)
        openSession(hostSessionIdentifier: activity.hostSessionIdentifier)
        nextEventPollTime = 0
        return true
    }

    /// Asks the Claude app to show one session, or just comes forward when the session is unknown.
    func openSession(hostSessionIdentifier: String?) {
        guard let hostIdentifier = hostSessionIdentifier else {
            activateClaude()
            return
        }
        guard let link = URL(string: "claude://code/continue?session=\(hostIdentifier)") else {
            activateClaude()
            return
        }
        lastOpenedLink = link.absoluteString
        guard !isLinkOpeningDisabled else {
            return
        }
        NSWorkspace.shared.open(link)
    }

    // MARK: - Claude app

    /// Brings the Claude app to the front.
    func activateClaude() {
        lastOpenedLink = "activate"
        guard !isLinkOpeningDisabled else {
            return
        }
        let workspace = NSWorkspace.shared
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: PetConfig.claudeBundleIdentifier) else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration, completionHandler: nil)
    }

    /// Jumps onto the Claude window shortly after it was brought forward.
    func hopToClaudeWindowIfDue(now: TimeInterval) {
        guard let dueTime = pendingClaudeJumpTime, now >= dueTime else {
            return
        }
        pendingClaudeJumpTime = nil
        guard motion.isAwakeOnLedge else {
            return
        }

        // Look for a ledge on top of a Claude window
        let claudeApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: PetConfig.claudeBundleIdentifier
        )
        let claudeProcesses = Set(claudeApplications.map { $0.processIdentifier })
        surfaces = scanner.scan(clearance: bodyHeight)
        let claudeLedges = surfaces.filter { ledge in
            guard let ownerProcess = ledge.ownerProcess else {
                return false
            }
            return claudeProcesses.contains(ownerProcess)
        }

        // Hop on the spot when the window has no room on top
        guard let ledge = claudeLedges.max(by: { $0.width < $1.width }) else {
            playOnce("jumping")
            return
        }
        if let current = support, current.windowNumber == ledge.windowNumber {
            playOnce("waving")
            return
        }

        // Jump onto the window
        let margin = halfBodyWidth
        let landingX = min(max(footPoint.x, ledge.minimumX + margin), ledge.maximumX - margin)
        jump(toHeight: ledge.height, landingX: landingX)
    }
}
