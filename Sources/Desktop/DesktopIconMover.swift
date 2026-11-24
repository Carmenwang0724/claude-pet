import AppKit

/// Describes one place an icon should be moved to, in Finder's desktop coordinates.
private struct IconMove {
    let name: String
    let x: Int
    let y: Int
}

/// Moves single desktop icons by sending Finder its "set" event.
/// The many small moves made while the pet carries an icon go out from a background queue,
/// so a slow answer from Finder never holds up the pet.
final class DesktopIconMover: @unchecked Sendable {
    private let sendQueue = DispatchQueue(label: "local.claudepet.icon-mover", qos: .userInitiated)
    private let lock = NSLock()
    private let finderBundleIdentifier = "com.apple.finder"
    private let permissionErrorNumber = -1743
    private let timeoutErrorNumber = -1712
    private let replyTimeout: TimeInterval = 1

    // Keep the state below behind the lock
    private var waitingMove: IconMove?
    private var isDraining = false
    private var storedErrorNumber = 0
    private var storedLastDuration: TimeInterval = 0
    private var storedSlowestDuration: TimeInterval = 0
    private var storedSendCount = 0
    private var storedFailureCount = 0
    private var storedFailureStreak = 0

    // MARK: - Results

    /// Gives the error number of the last move, or zero when it went through.
    var lastErrorNumber: Int {
        return readLocked { storedErrorNumber }
    }

    /// Gives how long Finder took to answer the last move.
    var lastSendDuration: TimeInterval {
        return readLocked { storedLastDuration }
    }

    /// Gives the longest time Finder took to answer a move.
    var slowestSendDuration: TimeInterval {
        return readLocked { storedSlowestDuration }
    }

    /// Counts the moves sent so far.
    var sendCount: Int {
        return readLocked { storedSendCount }
    }

    /// Counts the moves that failed so far.
    var failureCount: Int {
        return readLocked { storedFailureCount }
    }

    /// Counts the moves that failed in a row up to now.
    var failureStreak: Int {
        return readLocked { storedFailureStreak }
    }

    /// Tells whether the last error means the user has not allowed control of Finder.
    var wasRefused: Bool {
        return lastErrorNumber == permissionErrorNumber
    }

    /// Tells whether Finder did not answer the last move in time.
    var hasTimedOut: Bool {
        return lastErrorNumber == timeoutErrorNumber
    }

    // MARK: - Moves

    /// Puts the centre of one icon at a place and waits for Finder's answer.
    func place(name: String, x: Int, y: Int) -> Bool {
        // Drop a move that is still waiting, so it cannot land after this one
        lock.lock()
        waitingMove = nil
        lock.unlock()

        // Let the move in flight finish, then send this one
        return sendQueue.sync {
            send(move: IconMove(name: name, x: x, y: y))
        }
    }

    /// Asks for one icon to be moved soon, without waiting. A newer request replaces one still waiting.
    func follow(name: String, x: Int, y: Int) {
        // Remember the newest place and see whether the queue is already at work
        lock.lock()
        waitingMove = IconMove(name: name, x: x, y: y)
        let needsDrain = !isDraining
        if needsDrain {
            isDraining = true
        }
        lock.unlock()

        // Start sending in the background
        if needsDrain {
            sendQueue.async { [self] in
                drainWaitingMoves()
            }
        }
    }

    /// Drops a move that is still waiting and waits for the one in flight to finish.
    func settle() {
        lock.lock()
        waitingMove = nil
        lock.unlock()
        sendQueue.sync {}
    }

    /// Sends the newest waiting move, again and again, until none is left.
    private func drainWaitingMoves() {
        while true {
            // Take the newest place, or stop when there is none
            lock.lock()
            guard let move = waitingMove else {
                isDraining = false
                lock.unlock()
                return
            }
            waitingMove = nil
            lock.unlock()
            _ = send(move: move)
        }
    }

    /// Sends one move to Finder, waits for the answer and keeps the result.
    private func send(move: IconMove) -> Bool {
        let event = makeEvent(move: move)
        let startedAt = CACurrentMediaTime()

        // Send the event and read the error number from the answer
        var errorNumber = 0
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: replyTimeout)
            if let errorDescriptor = reply.paramDescriptor(forKeyword: fourCharacterCode("errn")) {
                errorNumber = Int(errorDescriptor.int32Value)
            }
        } catch {
            errorNumber = (error as NSError).code
        }
        let duration = CACurrentMediaTime() - startedAt

        // Keep the timing and the result
        lock.lock()
        storedLastDuration = duration
        storedSlowestDuration = max(storedSlowestDuration, duration)
        storedSendCount += 1
        storedErrorNumber = errorNumber
        if errorNumber == 0 {
            storedFailureStreak = 0
        } else {
            storedFailureCount += 1
            storedFailureStreak += 1
        }
        lock.unlock()
        return errorNumber == 0
    }

    /// Reads a value while holding the lock.
    private func readLocked<Value>(_ read: () -> Value) -> Value {
        lock.lock()
        defer {
            lock.unlock()
        }
        return read()
    }

    // MARK: - Event

    /// Builds the event "set desktop position of item <name> of desktop to {x, y}".
    private func makeEvent(move: IconMove) -> NSAppleEventDescriptor {
        // Describe the property to change, from the outside in
        let desktop = makeSpecifier(
            desiredClass: "prop",
            keyForm: "prop",
            keyData: NSAppleEventDescriptor(typeCode: fourCharacterCode("desk")),
            container: NSAppleEventDescriptor.null()
        )
        let item = makeSpecifier(
            desiredClass: "cobj",
            keyForm: "name",
            keyData: NSAppleEventDescriptor(string: move.name),
            container: desktop
        )
        let position = makeSpecifier(
            desiredClass: "prop",
            keyForm: "prop",
            keyData: NSAppleEventDescriptor(typeCode: fourCharacterCode("dpos")),
            container: item
        )

        // Describe the new place
        let place = NSAppleEventDescriptor.list()
        place.insert(NSAppleEventDescriptor(int32: Int32(move.x)), at: 1)
        place.insert(NSAppleEventDescriptor(int32: Int32(move.y)), at: 2)

        // Address the event to Finder
        let event = NSAppleEventDescriptor(
            eventClass: fourCharacterCode("core"),
            eventID: fourCharacterCode("setd"),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: finderBundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(position, forKeyword: fourCharacterCode("----"))
        event.setParam(place, forKeyword: fourCharacterCode("data"))
        return event
    }

    /// Builds the description of one object inside its container.
    private func makeSpecifier(
        desiredClass: String,
        keyForm: String,
        keyData: NSAppleEventDescriptor,
        container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharacterCode(desiredClass)), forKeyword: fourCharacterCode("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCharacterCode(keyForm)), forKeyword: fourCharacterCode("form"))
        record.setDescriptor(keyData, forKeyword: fourCharacterCode("seld"))
        record.setDescriptor(container, forKeyword: fourCharacterCode("from"))
        return record.coerce(toDescriptorType: fourCharacterCode("obj ")) ?? record
    }

    /// Turns four characters into the number Apple events are named by.
    private func fourCharacterCode(_ text: String) -> FourCharCode {
        var code: FourCharCode = 0
        for scalar in text.unicodeScalars {
            code = (code << 8) + FourCharCode(scalar.value & 0xFF)
        }
        return code
    }
}
