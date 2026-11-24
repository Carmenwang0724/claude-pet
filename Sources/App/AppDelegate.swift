import AppKit

/// Starts the pet when the app launches and cleans up when it quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leave when another copy is already running
        if isAnotherCopyRunning() {
            NSApp.terminate(nil)
            return
        }

        // Set the switches that start out on
        UserDefaults.standard.register(defaults: PetConfig.defaultSwitches)

        // Record the process identifier for the hook script
        try? FileManager.default.createDirectory(at: PetConfig.stateDirectory, withIntermediateDirectories: true)
        let processLine = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? processLine.write(to: PetConfig.processIdentifierFile, atomically: true, encoding: .utf8)

        // Load the chosen pet
        guard let atlas = loadPreferredAtlas() else {
            showMissingPetAlert()
            NSApp.terminate(nil)
            return
        }

        // Start the pet
        let petController = PetController(atlas: atlas)
        petController.start()
        controller = petController
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Bring back any app hidden for a desktop trip
        controller?.closeCurtain()

        // Remove the process file when it belongs to this copy
        let ownLine = "\(ProcessInfo.processInfo.processIdentifier)\n"
        let storedLine = try? String(contentsOf: PetConfig.processIdentifierFile, encoding: .utf8)
        if storedLine == ownLine {
            try? FileManager.default.removeItem(at: PetConfig.processIdentifierFile)
        }
    }

    /// Checks for a second running copy of this app.
    private func isAnotherCopyRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        return copies.contains { $0.processIdentifier != ownProcess }
    }

    /// Loads the saved pet, falling back to the default and then to any installed pet.
    private func loadPreferredAtlas() -> PetAtlas? {
        // Order the candidates by preference
        let listings = PetLibrary.installedPets()
        let savedIdentifier = UserDefaults.standard.string(forKey: PetConfig.selectedPetKey)
        var orderedListings: [PetListing] = []
        orderedListings.append(contentsOf: listings.filter { $0.identifier == savedIdentifier })
        orderedListings.append(contentsOf: listings.filter { $0.identifier == PetConfig.defaultPetIdentifier })
        orderedListings.append(contentsOf: listings)

        // Return the first pet that loads
        for listing in orderedListings {
            do {
                let swapsRunningRows = PetPreferences.swapsRunningRows(identifier: listing.identifier)
                return try autoreleasepool {
                    try PetAtlas.load(folder: listing.folder, swapsRunningRows: swapsRunningRows)
                }
            } catch {
                NSLog("ClaudePet could not load \(listing.identifier): \(error)")
            }
        }
        return nil
    }

    /// Tells the user where pets are expected.
    private func showMissingPetAlert() {
        let alert = NSAlert()
        alert.messageText = "No pet found"
        alert.informativeText = "Put a pet folder in ~/.petdex/pets or ~/.codex/pets. Each folder needs pet.json and spritesheet.webp."
        alert.runModal()
    }
}
