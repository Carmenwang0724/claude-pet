import AppKit

/// Holds the entry point of the app.
@main
@MainActor
enum Launcher {
    private static let delegate = AppDelegate()

    static func main() {
        // Handle the atlas check command
        let arguments = CommandLine.arguments
        if arguments.count == 4 && arguments[1] == "--dump-atlas" {
            exit(AtlasDump.run(petFolderPath: arguments[2], outputPath: arguments[3]))
        }

        // Handle the atlas cutting command
        if arguments.count == 5 && arguments[1] == "--build-cache" {
            let status = PetAtlasBuilder.run(
                petFolderPath: arguments[2],
                cacheFolderPath: arguments[3],
                walkRowLayout: WalkRowLayout(rawValue: arguments[4]) ?? .asDrawn
            )
            exit(status)
        }

        // Start the app without a Dock icon
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
