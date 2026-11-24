import AppKit

/// Describes how a desktop request ended.
enum MischiefOutcome {
    case done(detail: String)
    case doneNeedingManualSort(sortName: String)
    case notAllowed
    case failed(message: String)
}

/// Describes one desktop icon, in Finder's coordinates.
struct DesktopIcon {
    let name: String
    let x: Int
    let y: Int

    /// Tells whether the icon has a place of its own, or is laid out by Finder.
    var isPlaced: Bool {
        return x >= 0 && y >= 0
    }
}

/// Describes what came back from getting ready to mess up the desktop.
enum MessPreparation {
    case ready(icons: [DesktopIcon])
    case needsConfirmation(sortName: String)
    case notAllowed
    case failed(message: String)
}

/// Describes one icon that is away from its saved place, in Finder's coordinates.
struct StrayIcon {
    let name: String
    let currentX: Int
    let currentY: Int
    let homeX: Int
    let homeY: Int
}

/// Describes what came back from getting ready to tidy the desktop.
enum TidyPreparation {
    case ready(strays: [StrayIcon])
    case notAllowed
    case failed(message: String)
}

/// Records where one desktop icon sits, in Finder's coordinates.
private struct DesktopItem: Codable {
    var name: String
    var x: Int
    var y: Int
}

/// Keeps what is needed to put the desktop back.
private struct DesktopSnapshot: Codable {
    var arrangement: String
    var manualSortName: String?
    var items: [DesktopItem]
}

/// Carries the result of one AppleScript run.
private struct ScriptResult {
    let status: Int32
    let output: String
    let errorText: String

    /// Tells whether the user has not allowed control of Finder.
    var isRefused: Bool {
        return errorText.contains("-1743") || errorText.contains("Not authorized")
    }

    /// Gives the first line of the error as a short message.
    var failureMessage: String {
        let firstLine = errorText.split(separator: "\n").first.map(String.init) ?? "status \(status)"
        return "Finder refused: \(firstLine)"
    }
}

/// Reads the desktop through Finder, saves its layout, and restores it.
@MainActor
final class DesktopMischief {
    private(set) var isBusy = false

    private let unsortedArrangement = "not arranged"
    private let busyMessage = "Still busy with the last request"
    private let freePlacementSorts: Set<String> = ["", "none", "grid"]
    private let sortDisplayNames = [
        "name": "Name",
        "kind": "Kind",
        "size": "Size",
        "label": "Tags",
        "dateAdded": "Date Added",
        "dateModified": "Date Modified",
        "dateCreated": "Date Created",
        "dateLastOpened": "Date Last Opened",
    ]

    private let readArrangementScript = """
        tell application "Finder" to get arrangement of icon view options of window of desktop
        """

    private let readItemsScript = """
        tell application "Finder"
            set itemNames to name of every item of desktop
            set itemPositions to desktop position of every item of desktop
        end tell
        set outputLines to {}
        repeat with itemIndex from 1 to count of itemNames
            set itemPosition to item itemIndex of itemPositions
            set positionText to ((item 1 of itemPosition) as text) & tab & ((item 2 of itemPosition) as text)
            set end of outputLines to positionText & tab & (item itemIndex of itemNames)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return outputLines as text
        """

    /// Tells whether a saved desktop layout is waiting to be restored.
    var hasSnapshot: Bool {
        return FileManager.default.fileExists(atPath: PetConfig.desktopSnapshotFile.path)
    }

    /// Reads the size of the desktop icons from Finder's settings.
    var desktopIconSize: CGFloat {
        let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
        let desktopSettings = finderDefaults?.dictionary(forKey: "DesktopViewSettings")
        let iconSettings = desktopSettings?["IconViewSettings"] as? [String: Any]
        let storedSize = (iconSettings?["iconSize"] as? NSNumber)?.doubleValue ?? 0
        return storedSize > 0 ? CGFloat(storedSize) : PetConfig.fallbackDesktopIconSize
    }

    // MARK: - Requests

    /// Reads the desktop without changing it.
    func probe(completion: @escaping (MischiefOutcome) -> Void) {
        guard begin() else {
            completion(.failed(message: busyMessage))
            return
        }
        runScript(source: readItemsScript, usesSourceForm: false) { [self] itemsResult in
            guard itemsResult.status == 0 else {
                end(outcome(from: itemsResult), completion: completion)
                return
            }

            // Save the positions for comparing later
            let items = parseItems(text: itemsResult.output)
            if let probeData = try? JSONEncoder().encode(items) {
                try? probeData.write(to: PetConfig.desktopProbeFile, options: .atomic)
            }
            runScript(source: readArrangementScript, usesSourceForm: true) { [self] arrangementResult in
                let arrangement = arrangementResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let savedSort = finderSortPreference() ?? "unset"
                let detail = "\(items.count) items, script arrangement [\(arrangement)], saved sort [\(savedSort)]"
                end(MischiefOutcome.done(detail: detail), completion: completion)
            }
        }
    }

    /// Saves the layout, turns off the sorting, and picks the icons to carry away.
    func prepareMess(iconCount: Int, allowsManualSort: Bool, completion: @escaping (MessPreparation) -> Void) {
        guard begin() else {
            completion(.failed(message: busyMessage))
            return
        }

        // Read where every icon is
        runScript(source: readItemsScript, usesSourceForm: false) { [self] itemsResult in
            guard itemsResult.status == 0 else {
                end(messFailure(from: itemsResult), completion: completion)
                return
            }
            let items = parseItems(text: itemsResult.output)
            guard !items.isEmpty else {
                end(MessPreparation.failed(message: "There are no icons on the desktop"), completion: completion)
                return
            }

            // Go straight on when the original layout is already saved
            if let snapshot = loadSnapshot() {
                turnSortingOff(items: items, homeItems: snapshot.items, iconCount: iconCount, completion: completion)
                return
            }

            // Read how the desktop is sorted
            runScript(source: readArrangementScript, usesSourceForm: true) { [self] arrangementResult in
                guard arrangementResult.status == 0 else {
                    end(messFailure(from: arrangementResult), completion: completion)
                    return
                }
                let arrangement = arrangementResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

                // Ask first when the sorting cannot be switched back on by script
                let manualSortName = sortNeedingManualRestore(scriptArrangement: arrangement)
                if let manualSortName = manualSortName, !allowsManualSort {
                    end(MessPreparation.needsConfirmation(sortName: manualSortName), completion: completion)
                    return
                }

                // Save the original layout and sorting
                let snapshot = DesktopSnapshot(arrangement: arrangement, manualSortName: manualSortName, items: items)
                guard save(snapshot: snapshot) else {
                    let message = "Could not save the layout, so nothing was moved"
                    end(MessPreparation.failed(message: message), completion: completion)
                    return
                }
                turnSortingOff(items: items, homeItems: items, iconCount: iconCount, completion: completion)
            }
        }
    }

    /// Lists the icons that are away from their saved places.
    func prepareTidy(completion: @escaping (TidyPreparation) -> Void) {
        guard let snapshot = loadSnapshot() else {
            completion(.failed(message: "Nothing to tidy"))
            return
        }
        guard begin() else {
            completion(.failed(message: busyMessage))
            return
        }
        runScript(source: readItemsScript, usesSourceForm: false) { [self] itemsResult in
            guard itemsResult.status == 0 else {
                let failure = itemsResult.isRefused ? TidyPreparation.notAllowed : .failed(message: itemsResult.failureMessage)
                end(failure, completion: completion)
                return
            }

            // Compare every icon with its saved place
            let homeByName = itemsByName(snapshot.items)
            var strays: [StrayIcon] = []
            for item in parseItems(text: itemsResult.output) {
                guard let home = homeByName[item.name] else {
                    continue
                }
                if home.x != item.x || home.y != item.y {
                    strays.append(
                        StrayIcon(name: item.name, currentX: item.x, currentY: item.y, homeX: home.x, homeY: home.y)
                    )
                }
            }
            end(TidyPreparation.ready(strays: strays), completion: completion)
        }
    }

    /// Puts every icon at its saved place, restores the sorting when a script can, and forgets the saved layout.
    func finishTidy(completion: @escaping (MischiefOutcome) -> Void) {
        guard let snapshot = loadSnapshot() else {
            completion(.failed(message: "Nothing to tidy"))
            return
        }
        guard begin() else {
            completion(.failed(message: busyMessage))
            return
        }

        // Put every icon back where it was
        runScript(source: restoreScript(items: snapshot.items), usesSourceForm: false) { [self] restoreResult in
            guard restoreResult.status == 0 else {
                end(outcome(from: restoreResult), completion: completion)
                return
            }

            // Leave the sorting to the user when a script cannot name it
            if let manualSortName = snapshot.manualSortName {
                try? FileManager.default.removeItem(at: PetConfig.desktopSnapshotFile)
                end(MischiefOutcome.doneNeedingManualSort(sortName: manualSortName), completion: completion)
                return
            }

            // Finish here when the desktop was not sorted to begin with
            let wasUnsorted = snapshot.arrangement.isEmpty || snapshot.arrangement == unsortedArrangement
            guard !wasUnsorted else {
                try? FileManager.default.removeItem(at: PetConfig.desktopSnapshotFile)
                end(MischiefOutcome.done(detail: "restored \(snapshot.items.count) items"), completion: completion)
                return
            }

            // Turn the original sorting back on
            let arrangementScript = setArrangementScript(value: snapshot.arrangement)
            runScript(source: arrangementScript, usesSourceForm: false) { [self] arrangementResult in
                guard arrangementResult.status == 0 else {
                    let message = "Icons are back. Re-select the sort order from the desktop's right-click menu."
                    end(MischiefOutcome.failed(message: message), completion: completion)
                    return
                }
                try? FileManager.default.removeItem(at: PetConfig.desktopSnapshotFile)
                let detail = "restored \(snapshot.items.count) items, arrangement \(snapshot.arrangement)"
                end(MischiefOutcome.done(detail: detail), completion: completion)
            }
        }
    }

    // MARK: - Steps

    /// Turns off the sorting and picks icons that are still at their saved places.
    private func turnSortingOff(
        items: [DesktopItem],
        homeItems: [DesktopItem],
        iconCount: Int,
        completion: @escaping (MessPreparation) -> Void
    ) {
        let arrangementScript = setArrangementScript(value: unsortedArrangement)
        runScript(source: arrangementScript, usesSourceForm: false) { [self] arrangementResult in
            guard arrangementResult.status == 0 else {
                end(messFailure(from: arrangementResult), completion: completion)
                return
            }

            // Keep the icons that have not been carried away yet
            let homeByName = itemsByName(homeItems)
            let candidates = items.filter { item in
                guard !item.name.contains("\n"), !item.name.contains("\r") else {
                    return false
                }
                guard let home = homeByName[item.name] else {
                    return false
                }
                return home.x == item.x && home.y == item.y
            }
            let chosenIcons = candidates.shuffled().prefix(iconCount).map { item in
                DesktopIcon(name: item.name, x: item.x, y: item.y)
            }
            guard !chosenIcons.isEmpty else {
                end(MessPreparation.failed(message: "Every icon is already out of place"), completion: completion)
                return
            }
            end(MessPreparation.ready(icons: Array(chosenIcons)), completion: completion)
        }
    }

    /// Turns a failed script run into a mess preparation result.
    private func messFailure(from result: ScriptResult) -> MessPreparation {
        return result.isRefused ? .notAllowed : .failed(message: result.failureMessage)
    }

    /// Turns a failed script run into an outcome.
    private func outcome(from result: ScriptResult) -> MischiefOutcome {
        return result.isRefused ? .notAllowed : .failed(message: result.failureMessage)
    }

    // MARK: - Sorting

    /// Reads the desktop sorting that Finder keeps in its settings.
    private func finderSortPreference() -> String? {
        let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
        let desktopSettings = finderDefaults?.dictionary(forKey: "DesktopViewSettings")
        let iconSettings = desktopSettings?["IconViewSettings"] as? [String: Any]
        return iconSettings?["arrangeBy"] as? String
    }

    /// Names the sorting when Finder has one that its scripting cannot express.
    private func sortNeedingManualRestore(scriptArrangement: String) -> String? {
        // Trust the script when it reports a real sorting
        guard scriptArrangement == unsortedArrangement else {
            return nil
        }

        // Compare with what Finder keeps in its settings
        guard let savedSort = finderSortPreference(), !freePlacementSorts.contains(savedSort) else {
            return nil
        }
        return sortDisplayNames[savedSort] ?? savedSort
    }

    // MARK: - Scripts

    /// Writes the script that puts every saved icon back, skipping the ones that are gone.
    private func restoreScript(items: [DesktopItem]) -> String {
        var lines = ["tell application \"Finder\""]
        for item in items where !item.name.contains("\n") && !item.name.contains("\r") {
            lines.append("    try")
            lines.append("        set desktop position of item \(quoted(item.name)) of desktop to {\(item.x), \(item.y)}")
            lines.append("    end try")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Writes the script that sets how the desktop is sorted.
    private func setArrangementScript(value: String) -> String {
        return "tell application \"Finder\" to set arrangement of icon view options of window of desktop to \(value)"
    }

    /// Wraps a file name as an AppleScript string.
    private func quoted(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Reads the lines of positions and names printed by the items script.
    private func parseItems(text: String) -> [DesktopItem] {
        var items: [DesktopItem] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                continue
            }
            guard let x = Double(fields[0]), let y = Double(fields[1]) else {
                continue
            }
            items.append(DesktopItem(name: String(fields[2]), x: Int(x), y: Int(y)))
        }
        return items
    }

    /// Indexes a list of icons by file name.
    private func itemsByName(_ items: [DesktopItem]) -> [String: DesktopItem] {
        var byName: [String: DesktopItem] = [:]
        for item in items {
            byName[item.name] = item
        }
        return byName
    }

    // MARK: - Snapshot

    /// Writes the saved layout to disk.
    private func save(snapshot: DesktopSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return false
        }
        do {
            try data.write(to: PetConfig.desktopSnapshotFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Reads the saved layout from disk.
    private func loadSnapshot() -> DesktopSnapshot? {
        guard let data = try? Data(contentsOf: PetConfig.desktopSnapshotFile) else {
            return nil
        }
        return try? JSONDecoder().decode(DesktopSnapshot.self, from: data)
    }

    // MARK: - Running

    /// Marks the start of a request and reports whether it may go ahead.
    private func begin() -> Bool {
        guard !isBusy else {
            return false
        }
        isBusy = true
        return true
    }

    /// Marks the end of a request and hands over its result.
    private func end<Result>(_ result: Result, completion: (Result) -> Void) {
        isBusy = false
        completion(result)
    }

    /// Runs an AppleScript in a separate process and reports back on the main thread.
    private func runScript(source: String, usesSourceForm: Bool, completion: @escaping (ScriptResult) -> Void) {
        // Set up the osascript process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = usesSourceForm ? ["-s", "s", "-e", source] : ["-e", source]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Collect the output when it ends
        process.terminationHandler = { finishedProcess in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let result = ScriptResult(
                status: finishedProcess.terminationStatus,
                output: String(decoding: outputData, as: UTF8.self),
                errorText: String(decoding: errorData, as: UTF8.self)
            )
            DispatchQueue.main.async {
                completion(result)
            }
        }

        // Start it
        do {
            try process.run()
        } catch {
            completion(ScriptResult(status: -1, output: "", errorText: "\(error)"))
        }
    }
}
