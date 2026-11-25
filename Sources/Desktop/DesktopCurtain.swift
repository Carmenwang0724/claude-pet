import AppKit

/// Hides the windows of the other apps so the desktop can be seen, and brings them back afterwards.
@MainActor
final class DesktopCurtain {
    private var hiddenApplications: [NSRunningApplication] = []
    private var previousFrontmostApplication: NSRunningApplication?
    private let finderBundleIdentifier = "com.apple.finder"

    /// Tells whether apps hidden by the curtain are waiting to come back.
    var isOpen: Bool {
        return !hiddenApplications.isEmpty
    }

    /// Counts the apps the curtain is holding back.
    var hiddenCount: Int {
        return hiddenApplications.count
    }

    /// Hides every ordinary app that is showing, except Finder and the pet, and returns how many it hid.
    func open() -> Int {
        let workspace = NSWorkspace.shared
        let ownProcess = ProcessInfo.processInfo.processIdentifier

        // Remember the app in front, only the first time
        if hiddenApplications.isEmpty {
            previousFrontmostApplication = workspace.frontmostApplication
        }

        // Hide the ordinary apps that are showing
        var newlyHiddenCount = 0
        for application in workspace.runningApplications {
            guard application.activationPolicy == .regular, !application.isHidden else {
                continue
            }
            guard application.processIdentifier != ownProcess else {
                continue
            }
            guard application.bundleIdentifier != finderBundleIdentifier else {
                continue
            }
            let isAlreadyHeld = hiddenApplications.contains { $0.processIdentifier == application.processIdentifier }
            guard !isAlreadyHeld else {
                continue
            }

            // Keep the app whatever hide() answers, since it can report false and still hide the app
            _ = application.hide()
            hiddenApplications.append(application)
            newlyHiddenCount += 1
        }
        return newlyHiddenCount
    }

    /// Shows the hidden apps again and brings the app that was in front back to the front.
    func close() {
        guard !hiddenApplications.isEmpty else {
            return
        }

        // Show the apps again, whatever unhide() answers
        for application in hiddenApplications where !application.isTerminated {
            _ = application.unhide()
        }
        hiddenApplications = []

        // Bring back the app that was in front, unless it was Finder or has quit
        let frontmost = previousFrontmostApplication
        previousFrontmostApplication = nil
        guard let frontmost = frontmost, !frontmost.isTerminated else {
            return
        }
        guard frontmost.bundleIdentifier != finderBundleIdentifier, let applicationURL = frontmost.bundleURL else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration, completionHandler: nil)
    }
}
