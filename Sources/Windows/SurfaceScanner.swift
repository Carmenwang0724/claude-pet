import AppKit

/// Describes a horizontal ledge the pet can stand on, in AppKit screen coordinates.
struct Surface {
    let windowNumber: CGWindowID?
    let ownerProcess: pid_t?
    let height: CGFloat
    let minimumX: CGFloat
    let maximumX: CGFloat
    let windowFrame: CGRect?

    /// Tells whether the ledge is the bottom of a screen.
    var isFloor: Bool {
        return windowNumber == nil
    }

    /// Gives the length of the ledge.
    var width: CGFloat {
        return maximumX - minimumX
    }

    /// Reports whether a horizontal position lies on the ledge.
    func contains(x: CGFloat, tolerance: CGFloat = 0) -> Bool {
        return x >= minimumX - tolerance && x <= maximumX + tolerance
    }
}

/// Carries the facts read about one ordinary window.
private struct WindowRecord {
    let windowNumber: CGWindowID?
    let ownerProcess: pid_t
    let frame: CGRect
}

/// Reads the on-screen windows and turns their visible top edges into ledges.
@MainActor
final class SurfaceScanner {
    private let ledgeWindowSize = CGSize(width: PetConfig.minimumWindowWidth, height: PetConfig.minimumWindowHeight)
    private let smallestCoveringSize = CGSize(width: 24, height: 24)

    /// Lists every ledge that has the given clearance above it.
    func scan(clearance: CGFloat) -> [Surface] {
        // Start with one floor per screen
        var surfaces = floors()

        // Read the window list, front window first
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return surfaces
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownProcess = ProcessInfo.processInfo.processIdentifier

        // Walk from the front window to the back window
        var coveringFrames: [CGRect] = []
        for entry in entries {
            let record = readWindow(
                entry: entry,
                ownProcess: ownProcess,
                primaryHeight: primaryHeight,
                minimumSize: ledgeWindowSize
            )
            guard let record = record else {
                continue
            }

            // Cut away the parts hidden by windows in front
            let ledgeHeight = record.frame.maxY
            var spans = [record.frame.minX...record.frame.maxX]
            for covering in coveringFrames {
                let reachesLedge = covering.minY < ledgeHeight + clearance && covering.maxY > ledgeHeight
                if reachesLedge {
                    spans = subtract(spans: spans, cutMinimum: covering.minX, cutMaximum: covering.maxX)
                }
            }

            // Keep the spans that have room above them
            for span in spans {
                if let ledge = makeLedge(span: span, clearance: clearance, record: record) {
                    surfaces.append(ledge)
                }
            }
            coveringFrames.append(record.frame)
        }
        return surfaces
    }

    /// Lists the frames of the ordinary windows of other apps, whatever their size.
    func windowFrames() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        var frames: [CGRect] = []
        for entry in entries {
            let record = readWindow(
                entry: entry,
                ownProcess: ownProcess,
                primaryHeight: primaryHeight,
                minimumSize: smallestCoveringSize
            )
            if let record = record {
                frames.append(record.frame)
            }
        }
        return frames
    }

    /// Builds the floor ledge of every screen.
    private func floors() -> [Surface] {
        return NSScreen.screens.map { screen in
            Surface(
                windowNumber: nil,
                ownerProcess: nil,
                height: screen.visibleFrame.minY,
                minimumX: screen.visibleFrame.minX,
                maximumX: screen.visibleFrame.maxX,
                windowFrame: nil
            )
        }
    }

    /// Reads one window list entry, or returns nil for anything but an ordinary window.
    private func readWindow(
        entry: [String: Any],
        ownProcess: pid_t,
        primaryHeight: CGFloat,
        minimumSize: CGSize
    ) -> WindowRecord? {
        // Keep ordinary windows of other apps
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else {
            return nil
        }
        guard let ownerProcess = entry[kCGWindowOwnerPID as String] as? pid_t, ownerProcess != ownProcess else {
            return nil
        }
        let opacity = entry[kCGWindowAlpha as String] as? Double ?? 1
        guard opacity > 0.05 else {
            return nil
        }

        // Read the window bounds
        guard let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        guard let quartzFrame = CGRect(dictionaryRepresentation: boundsDictionary) else {
            return nil
        }
        guard quartzFrame.width >= minimumSize.width, quartzFrame.height >= minimumSize.height else {
            return nil
        }

        // Convert from top-left to bottom-left coordinates
        let frame = CGRect(
            x: quartzFrame.minX,
            y: primaryHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        return WindowRecord(
            windowNumber: entry[kCGWindowNumber as String] as? CGWindowID,
            ownerProcess: ownerProcess,
            frame: frame
        )
    }

    /// Removes one interval from a list of spans.
    private func subtract(
        spans: [ClosedRange<CGFloat>],
        cutMinimum: CGFloat,
        cutMaximum: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        var remaining: [ClosedRange<CGFloat>] = []
        for span in spans {
            if cutMaximum <= span.lowerBound || cutMinimum >= span.upperBound {
                remaining.append(span)
                continue
            }
            if cutMinimum > span.lowerBound {
                remaining.append(span.lowerBound...cutMinimum)
            }
            if cutMaximum < span.upperBound {
                remaining.append(cutMaximum...span.upperBound)
            }
        }
        return remaining
    }

    /// Turns a visible span into a ledge when it sits inside a screen with room above.
    private func makeLedge(span: ClosedRange<CGFloat>, clearance: CGFloat, record: WindowRecord) -> Surface? {
        // Find the screen under the middle of the span
        let height = record.frame.maxY
        let middle = CGPoint(x: (span.lowerBound + span.upperBound) / 2, y: height - 1)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) else {
            return nil
        }
        let visibleFrame = screen.visibleFrame

        // Require room above and a rise above the floor
        guard height + clearance <= visibleFrame.maxY else {
            return nil
        }
        guard height >= visibleFrame.minY + PetConfig.minimumLedgeRise else {
            return nil
        }

        // Clip the span to the screen
        let minimumX = max(span.lowerBound, visibleFrame.minX)
        let maximumX = min(span.upperBound, visibleFrame.maxX)
        guard maximumX - minimumX >= PetConfig.minimumLedgeWidth else {
            return nil
        }
        return Surface(
            windowNumber: record.windowNumber,
            ownerProcess: record.ownerProcess,
            height: height,
            minimumX: minimumX,
            maximumX: maximumX,
            windowFrame: record.frame
        )
    }
}
