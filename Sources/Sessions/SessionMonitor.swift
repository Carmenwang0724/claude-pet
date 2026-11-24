import Foundation

/// Names what Claude needs from the pet's point of view.
enum AgentState: String {
    case idle
    case running
    case waitingForPermission
    case waitingForAnswer
    case review
}

/// Summarises every Claude session as one state and one label.
struct AgentSummary: Equatable {
    var state: AgentState
    var label: String?
}

/// Names a one-time event worth a reaction.
enum AgentMoment {
    case sessionStarted
    case turnFinished
    case turnFailed
}

/// Names what one session needs, most urgent first.
enum ActivityStatus: Int {
    case needsPermission
    case needsAnswer
    case blocked
    case ready
    case running

    /// Gives a short name for the debug report.
    var name: String {
        switch self {
        case .needsPermission:
            return "needs-permission"
        case .needsAnswer:
            return "needs-answer"
        case .blocked:
            return "blocked"
        case .ready:
            return "ready"
        case .running:
            return "running"
        }
    }
}

/// Describes one session for the activity board.
struct SessionActivity: Equatable {
    let sessionIdentifier: String
    let hostSessionIdentifier: String?
    let title: String
    let status: ActivityStatus
    let since: TimeInterval
}

/// Keeps what is known about one Claude session.
private struct SessionRecord {
    var isRunning = false
    var pendingPermissions: [String: Int] = [:]
    var pendingQuestions: Set<String> = []
    var hasPermissionNotice = false
    var hasQuestionNotice = false
    var turnStartedAt: TimeInterval?
    var waitingSince: TimeInterval?
    var finishedAt: TimeInterval?
    var failedAt: TimeInterval?
    var reviewStartedAt: TimeInterval?
    var lastEventAt: TimeInterval = 0
    var lastInterruptCheckAt: TimeInterval = 0
    var title: String?
    var directory: String?
    var hostSessionIdentifier: String?
    var transcriptPath: String?

    /// Tells whether Claude is blocked on a permission prompt.
    var isWaitingForPermission: Bool {
        return !pendingPermissions.isEmpty || hasPermissionNotice
    }

    /// Tells whether Claude is blocked on a question.
    var isWaitingForAnswer: Bool {
        return !pendingQuestions.isEmpty || hasQuestionNotice
    }

    /// Forgets every pending prompt.
    mutating func clearWaiting() {
        pendingPermissions.removeAll()
        pendingQuestions.removeAll()
        hasPermissionNotice = false
        hasQuestionNotice = false
        waitingSince = nil
    }

    /// Notes when the session began waiting for the user.
    mutating func markWaiting(at time: TimeInterval) {
        if waitingSince == nil {
            waitingSince = time
        }
    }
}

/// Follows the hook event log and tracks the state of each Claude session.
@MainActor
final class SessionMonitor {
    private var sessions: [String: SessionRecord] = [:]
    private var readOffset: UInt64 = 0
    private let desktopTitles = DesktopSessionTitles()

    private let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    private let permissionNotices: Set<String> = ["permission_prompt", "worker_permission_prompt"]
    private let questionNotices: Set<String> = ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]
    private let interruptionMarker = "[Request interrupted by user"
    private let hostIdentifierPattern = "^local_[A-Za-z0-9-]{1,64}$"
    private let timestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    /// Creates the state folder and starts from an empty event log.
    func prepare() {
        try? FileManager.default.createDirectory(at: PetConfig.stateDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: PetConfig.eventsFile.path, contents: Data())
        readOffset = 0
    }

    /// Applies the events written since the last call and returns the moments they caused.
    func poll() -> [AgentMoment] {
        // Apply the new events
        var moments: [AgentMoment] = []
        for line in readNewLines() {
            guard let data = line.data(using: .utf8) else {
                continue
            }
            guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            if let moment = apply(fields: fields) {
                moments.append(moment)
            }
        }

        // Notice turns the user cut short
        checkInterruptions(now: Date().timeIntervalSince1970)
        return moments
    }

    /// Reduces every session to the single most urgent state for the pet's pose.
    func summary(now: TimeInterval) -> AgentSummary {
        // Drop sessions that have been silent for too long
        sessions = sessions.filter { now - $0.value.lastEventAt < PetConfig.sessionExpiry }

        // Order sessions from newest to oldest
        let records = sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }

        // Report the most urgent state
        if let record = records.first(where: { $0.isWaitingForPermission }) {
            return AgentSummary(state: .waitingForPermission, label: label(for: record))
        }
        if let record = records.first(where: { $0.isWaitingForAnswer }) {
            return AgentSummary(state: .waitingForAnswer, label: label(for: record))
        }
        if let record = records.first(where: { $0.isRunning && now - $0.lastEventAt < PetConfig.runningTimeout }) {
            return AgentSummary(state: .running, label: label(for: record))
        }
        let isFresh: (SessionRecord) -> Bool = { record in
            guard let startedAt = record.reviewStartedAt else {
                return false
            }
            return now - startedAt < PetConfig.reviewDuration
        }
        if let record = records.first(where: isFresh) {
            return AgentSummary(state: .review, label: label(for: record))
        }
        return AgentSummary(state: .idle, label: nil)
    }

    /// Lists every session that needs attention or is still working, most urgent first.
    func activities(now: TimeInterval) -> [SessionActivity] {
        var listed: [SessionActivity] = []
        for (identifier, record) in sessions {
            // Work out what the session needs
            let status: ActivityStatus
            let since: TimeInterval
            if record.isWaitingForPermission {
                status = .needsPermission
                since = record.waitingSince ?? record.lastEventAt
            } else if record.isWaitingForAnswer {
                status = .needsAnswer
                since = record.waitingSince ?? record.lastEventAt
            } else if let failedAt = record.failedAt {
                status = .blocked
                since = failedAt
            } else if let finishedAt = record.finishedAt {
                status = .ready
                since = finishedAt
            } else if record.isRunning && now - record.lastEventAt < PetConfig.runningListTimeout {
                status = .running
                since = record.turnStartedAt ?? record.lastEventAt
            } else {
                continue
            }
            listed.append(
                SessionActivity(
                    sessionIdentifier: identifier,
                    hostSessionIdentifier: record.hostSessionIdentifier,
                    title: label(for: record) ?? "Untitled",
                    status: status,
                    since: since
                )
            )
        }

        // Put the most urgent first, then the most recent
        return listed.sorted { first, second in
            if first.status != second.status {
                return first.status.rawValue < second.status.rawValue
            }
            if first.since != second.since {
                return first.since > second.since
            }
            return first.sessionIdentifier < second.sessionIdentifier
        }
    }

    /// Marks one finished or failed session as seen.
    func acknowledge(sessionIdentifier: String) {
        sessions[sessionIdentifier]?.finishedAt = nil
        sessions[sessionIdentifier]?.failedAt = nil
        sessions[sessionIdentifier]?.reviewStartedAt = nil
    }

    /// Ends the short review pose without clearing the board.
    func acknowledgeReviews() {
        for identifier in sessions.keys {
            sessions[identifier]?.reviewStartedAt = nil
        }
    }

    /// Forgets every session.
    func clearAll() {
        sessions.removeAll()
    }

    /// Describes every session for the debug report.
    func debugReport() -> [[String: Any]] {
        return sessions.map { identifier, record in
            [
                "session": String(identifier.prefix(8)),
                "host": record.hostSessionIdentifier ?? "",
                "isRunning": record.isRunning,
                "pendingPermissions": record.pendingPermissions,
                "pendingQuestions": Array(record.pendingQuestions).sorted(),
                "finishedAt": record.finishedAt ?? 0,
                "failedAt": record.failedAt ?? 0,
                "lastEventAt": record.lastEventAt,
                "hasTranscript": record.transcriptPath != nil,
                "label": label(for: record) ?? "",
            ]
        }
    }

    // MARK: - Events

    /// Updates one session from one hook event.
    private func apply(fields: [String: Any]) -> AgentMoment? {
        // Read the event fields
        guard let identifier = fields["session"] as? String, let event = fields["event"] as? String else {
            return nil
        }
        let time = fields["time"] as? TimeInterval ?? Date().timeIntervalSince1970
        let tool = fields["tool"] as? String ?? ""
        let notification = fields["notification"] as? String ?? ""

        // Forget a session that has ended
        if event == "SessionEnd" {
            sessions.removeValue(forKey: identifier)
            return nil
        }

        // Refresh the session details
        var record = sessions[identifier] ?? SessionRecord()
        record.lastEventAt = time
        refreshDetails(record: &record, fields: fields)

        // Apply the event
        var moment: AgentMoment?
        switch event {
        case "SessionStart":
            if fields["source"] as? String == "startup" {
                moment = .sessionStarted
            }
        case "UserPromptSubmit":
            record.isRunning = true
            record.turnStartedAt = time
            record.finishedAt = nil
            record.failedAt = nil
            record.reviewStartedAt = nil
            record.clearWaiting()
        case "PreToolUse":
            if !record.isRunning {
                record.turnStartedAt = time
            }
            record.isRunning = true
            record.finishedAt = nil
            record.failedAt = nil
            record.reviewStartedAt = nil
            if questionTools.contains(tool) {
                record.pendingQuestions.insert(tool)
                record.markWaiting(at: time)
            }
        case "PermissionRequest":
            record.pendingPermissions[tool, default: 0] += 1
            record.markWaiting(at: time)
        case "Elicitation":
            record.pendingQuestions.insert("Elicitation")
            record.markWaiting(at: time)
        case "ElicitationResult":
            record.pendingQuestions.remove("Elicitation")
            record.hasQuestionNotice = false
        case "Notification":
            if permissionNotices.contains(notification) {
                record.hasPermissionNotice = true
                record.markWaiting(at: time)
            }
            if questionNotices.contains(notification) {
                record.hasQuestionNotice = true
                record.markWaiting(at: time)
            }
        case "PostToolUse", "PostToolUseFailure":
            release(tool: tool, record: &record)
            record.isRunning = fields["interrupt"] as? Bool != true
        case "Stop":
            record.isRunning = false
            record.finishedAt = time
            record.failedAt = nil
            record.reviewStartedAt = time
            record.clearWaiting()
            moment = .turnFinished
        case "StopFailure":
            record.isRunning = false
            record.failedAt = time
            record.finishedAt = nil
            record.reviewStartedAt = nil
            record.clearWaiting()
            moment = .turnFailed
        default:
            break
        }

        // Stop counting the wait once nothing is pending
        if !record.isWaitingForPermission && !record.isWaitingForAnswer {
            record.waitingSince = nil
        }
        sessions[identifier] = record
        return moment
    }

    /// Copies the title, folder, host session and transcript path carried by an event.
    private func refreshDetails(record: inout SessionRecord, fields: [String: Any]) {
        if let title = fields["title"] as? String, !title.isEmpty {
            record.title = title
        }
        if let directory = fields["directory"] as? String, !directory.isEmpty {
            record.directory = directory
        }
        if let transcriptPath = fields["transcript"] as? String, !transcriptPath.isEmpty {
            record.transcriptPath = transcriptPath
        }
        if let hostIdentifier = fields["host"] as? String {
            let isValid = hostIdentifier.range(of: hostIdentifierPattern, options: .regularExpression) != nil
            if isValid {
                record.hostSessionIdentifier = hostIdentifier
            }
        }
    }

    /// Clears the prompts answered by a finished tool call.
    private func release(tool: String, record: inout SessionRecord) {
        if let count = record.pendingPermissions[tool] {
            record.pendingPermissions[tool] = count > 1 ? count - 1 : nil
        }
        record.pendingQuestions.remove(tool)
        record.hasPermissionNotice = false
        record.hasQuestionNotice = false
    }

    /// Picks a short name for a session.
    private func label(for record: SessionRecord) -> String? {
        if let title = record.title {
            return title
        }
        if let hostIdentifier = record.hostSessionIdentifier {
            let now = Date().timeIntervalSince1970
            let desktopTitle = desktopTitles.title(hostSessionIdentifier: hostIdentifier, now: now)
            if let desktopTitle = desktopTitle {
                return desktopTitle
            }
        }
        guard let directory = record.directory else {
            return nil
        }
        guard directory != PetConfig.homeDirectory.path else {
            return nil
        }
        return URL(fileURLWithPath: directory).lastPathComponent
    }

    // MARK: - Interruptions

    /// Marks quiet running sessions as stopped when their transcript shows the user cut the turn short.
    private func checkInterruptions(now: TimeInterval) {
        for identifier in Array(sessions.keys) {
            guard var record = sessions[identifier], record.isRunning else {
                continue
            }
            guard now - record.lastEventAt >= PetConfig.interruptQuietTime else {
                continue
            }
            guard now - record.lastInterruptCheckAt >= PetConfig.interruptCheckInterval else {
                continue
            }
            record.lastInterruptCheckAt = now

            // Look for an interruption written after the turn began
            let turnStart = record.turnStartedAt ?? record.lastEventAt
            if let transcriptPath = record.transcriptPath, wasInterrupted(transcriptPath: transcriptPath, after: turnStart) {
                record.isRunning = false
                record.clearWaiting()
            }
            sessions[identifier] = record
        }
    }

    /// Reads the end of a transcript and looks for an interruption entry newer than a given time.
    private func wasInterrupted(transcriptPath: String, after startTime: TimeInterval) -> Bool {
        // Read the tail of the file
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else {
            return false
        }
        defer {
            try? handle.close()
        }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let tailStart = fileSize > PetConfig.transcriptTailBytes ? fileSize - PetConfig.transcriptTailBytes : 0
        try? handle.seek(toOffset: tailStart)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)

        // Check each line that mentions the marker
        for line in text.split(separator: "\n") where line.contains(interruptionMarker) {
            guard let lineData = line.data(using: .utf8) else {
                continue
            }
            guard let entry = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }
            guard isInterruptionEntry(entry) else {
                continue
            }
            guard let stamp = entry["timestamp"] as? String, let date = timestampParser.date(from: stamp) else {
                continue
            }
            if date.timeIntervalSince1970 >= startTime - 2 {
                return true
            }
        }
        return false
    }

    /// Tells whether a transcript entry is the note Claude Code writes when the user interrupts.
    private func isInterruptionEntry(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "user" else {
            return false
        }
        let message = entry["message"] as? [String: Any]
        if let text = message?["content"] as? String {
            return text.hasPrefix(interruptionMarker)
        }
        let parts = message?["content"] as? [[String: Any]] ?? []
        return parts.contains { part in
            let isText = part["type"] as? String == "text"
            let text = part["text"] as? String ?? ""
            return isText && text.hasPrefix(interruptionMarker)
        }
    }

    // MARK: - Reading

    /// Reads the complete lines appended to the event log since the last call.
    private func readNewLines() -> [String] {
        // Leave early when the event log has not grown
        var fileStatus = stat()
        guard stat(PetConfig.eventsFile.path, &fileStatus) == 0 else {
            return []
        }
        guard UInt64(fileStatus.st_size) != readOffset else {
            return []
        }

        // Open the event log
        guard let handle = try? FileHandle(forReadingFrom: PetConfig.eventsFile) else {
            return []
        }
        defer {
            try? handle.close()
        }

        // Find the unread part
        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize < readOffset {
            readOffset = 0
        }
        guard fileSize > readOffset else {
            return []
        }
        try? handle.seek(toOffset: readOffset)
        let data = (try? handle.readToEnd()) ?? Data()

        // Keep only the lines that are complete
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return []
        }
        let complete = data[data.startIndex...lastNewline]
        readOffset += UInt64(complete.count)
        let text = String(decoding: complete, as: UTF8.self)

        // Empty the log once it has grown large
        if readOffset >= fileSize && fileSize > PetConfig.eventsFileLimit {
            FileManager.default.createFile(atPath: PetConfig.eventsFile.path, contents: Data())
            readOffset = 0
        }
        return text.split(separator: "\n").map(String.init)
    }
}
