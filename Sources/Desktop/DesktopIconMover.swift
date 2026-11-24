import AppKit

/// Moves single desktop icons by sending Finder its "set" event, quickly enough to follow the pet.
@MainActor
final class DesktopIconMover {
    private(set) var lastErrorNumber = 0
    private(set) var lastSendDuration: TimeInterval = 0
    private(set) var slowestSendDuration: TimeInterval = 0
    private(set) var sendCount = 0
    private(set) var failureCount = 0

    private let finderBundleIdentifier = "com.apple.finder"
    private let permissionErrorNumber = -1743
    private let timeoutErrorNumber = -1712
    private let replyTimeout: TimeInterval = 1

    /// Tells whether the last error means the user has not allowed control of Finder.
    var wasRefused: Bool {
        return lastErrorNumber == permissionErrorNumber
    }

    /// Tells whether Finder did not answer the last request in time.
    var hasTimedOut: Bool {
        return lastErrorNumber == timeoutErrorNumber
    }

    /// Puts the centre of one icon at a place given in Finder's desktop coordinates.
    func place(name: String, x: Int, y: Int) -> Bool {
        let event = makeEvent(name: name, x: x, y: y)
        let startedAt = CACurrentMediaTime()

        // Send the event and wait for Finder's answer
        var errorNumber = 0
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: replyTimeout)
            if let errorDescriptor = reply.paramDescriptor(forKeyword: fourCharacterCode("errn")) {
                errorNumber = Int(errorDescriptor.int32Value)
            }
        } catch {
            errorNumber = (error as NSError).code
        }

        // Keep the timing and the result for the caller
        lastSendDuration = CACurrentMediaTime() - startedAt
        slowestSendDuration = max(slowestSendDuration, lastSendDuration)
        sendCount += 1
        lastErrorNumber = errorNumber
        if errorNumber != 0 {
            failureCount += 1
        }
        return errorNumber == 0
    }

    /// Builds the event "set desktop position of item <name> of desktop to {x, y}".
    private func makeEvent(name: String, x: Int, y: Int) -> NSAppleEventDescriptor {
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
            keyData: NSAppleEventDescriptor(string: name),
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
        place.insert(NSAppleEventDescriptor(int32: Int32(x)), at: 1)
        place.insert(NSAppleEventDescriptor(int32: Int32(y)), at: 2)

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
