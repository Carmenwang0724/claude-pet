import AppKit

/// Collects the paths and tuning numbers shared across the app.
enum PetConfig {
    // Locate files
    static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    static let stateDirectory = homeDirectory.appendingPathComponent(".claude-pet", isDirectory: true)
    static let eventsFile = stateDirectory.appendingPathComponent("events.jsonl")
    static let processIdentifierFile = stateDirectory.appendingPathComponent("app.pid")
    static let debugRequestFile = stateDirectory.appendingPathComponent("debug-request")
    static let debugOutputFile = stateDirectory.appendingPathComponent("debug.json")
    static let desktopSnapshotFile = stateDirectory.appendingPathComponent("desktop-snapshot.json")
    static let atlasCacheDirectory = stateDirectory.appendingPathComponent("cache", isDirectory: true)
    static let desktopProbeFile = stateDirectory.appendingPathComponent("desktop-probe.json")
    static let desktopSessionsFolder = homeDirectory.appendingPathComponent(
        "Library/Application Support/Claude/claude-code-sessions",
        isDirectory: true
    )
    static let petLibraryFolders = [
        homeDirectory.appendingPathComponent(".petdex/pets", isDirectory: true),
        homeDirectory.appendingPathComponent(".codex/pets", isDirectory: true),
    ]

    // Name things
    static let defaultPetIdentifier = "claude-opus-scholar"
    static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    static let selectedPetKey = "selectedPetIdentifier"
    static let displayScaleKey = "displayScale"
    static let wanderingPausedKey = "wanderingPaused"
    static let climbingEnabledKey = "climbingEnabled"
    static let mousePlayEnabledKey = "mousePlayEnabled"
    static let remindersEnabledKey = "remindersEnabled"
    static let autoMischiefEnabledKey = "autoMischiefEnabled"
    static let manualSortAcceptedKey = "manualSortAccepted"
    static let boardCollapsedKey = "boardCollapsed"
    static let runningRowSwapKey = "runningRowSwapByPet"
    static let walkRowLayoutKey = "walkRowLayoutByPet"
    static let defaultWalkRowLayouts: [String: WalkRowLayout] = [
        "claude-opus-scholar": .swapped,
        "kirby": .rightMirrored,
    ]
    static let defaultSwitches: [String: Any] = [
        climbingEnabledKey: true,
        mousePlayEnabledKey: true,
        remindersEnabledKey: true,
        autoMischiefEnabledKey: true,
    ]

    // Describe the atlas grid
    static let atlasColumns = 8
    static let minimumAtlasRows = 9
    static let referenceCellAspect: CGFloat = 208.0 / 192.0
    static let opaqueAlphaThreshold: UInt8 = 24
    static let minimumOpaquePixels = 40
    static let maskBlockPixels = 4
    static let minimumClippedRun = 20
    static let expandedClipLimit = 2
    static let atlasCacheVersion = 1
    static let memoryReliefDelay: TimeInterval = 2

    // Pace the loop
    static let fastStepsPerSecond: Double = 30
    static let alertStepsPerSecond: Double = 20
    static let movingStepsPerSecond: Double = 15
    static let calmStepsPerSecond: Double = 10
    static let sleepingStepsPerSecond: Double = 4
    static let longestStep: TimeInterval = 0.25
    static let alertDistance: CGFloat = 170
    static let ridingScanInterval: TimeInterval = 1.0 / 15
    static let airborneScanInterval: TimeInterval = 0.1
    static let windowScanInterval: TimeInterval = 0.25
    static let floorScanInterval: TimeInterval = 0.75
    static let sleepingScanInterval: TimeInterval = 1.5
    static let eventPollInterval: TimeInterval = 0.3
    static let activityCheckInterval: TimeInterval = 1.0
    static let rideBoostDuration: TimeInterval = 1.0

    // Size the pet
    static let defaultDisplayScale: Double = 0.625
    static let displayScaleTitles = ["Small", "Medium", "Large", "Extra Large"]
    static let displayScaleValues: [Double] = [0.5, 0.625, 0.75, 1.0]

    // Move the pet
    static let walkSpeed: CGFloat = 58
    static let walkFrameDuration: TimeInterval = 0.11
    static let gravity: CGFloat = 2400
    static let maximumFallSpeed: CGFloat = 2600
    static let maximumThrowSpeed: CGFloat = 1800
    static let wallBounce: CGFloat = 0.35
    static let jumpReach: CGFloat = 520
    static let stepOffChance: Double = 0.35
    static let windowJumpChance: Double = 0.08
    static let idlePoseClips = ["waving", "review", "running", "waiting"]
    static let workingPoseChance: Double = 0.7
    static let dragStartDistance: CGFloat = 4
    static let dragTurnDistance: CGFloat = 3
    static let dragWalkLinger: TimeInterval = 0.3

    // Climb the screen edges
    static let climbSpeed: CGFloat = 46
    static let climbChance: Double = 0.25
    static let climbTripChance: Double = 0.04
    static let ceilingCrossChance: Double = 0.6

    // Play with the mouse
    static let cursorPersonalSpace: CGFloat = 220
    static let cursorPersonalSpaceAbove: CGFloat = 180
    static let cursorPersonalSpaceBelow: CGFloat = 80
    static let landingSpotTries = 4
    static let startleMouseSpeed: CGFloat = 1400
    static let startleDistance: CGFloat = 170
    static let startleCooldown: TimeInterval = 4
    static let pettingTravel: CGFloat = 140
    static let pettingReversals = 2
    static let pettingCooldown: TimeInterval = 3

    // Follow the user's rhythm
    static let sleepAfterIdle: TimeInterval = 5 * 60
    static let wakeIdleLimit: TimeInterval = 3
    static let breakIdleTime: TimeInterval = 3 * 60
    static let workStretch: TimeInterval = 50 * 60
    static let nightEndHour = 5
    static let nightNudgeInterval: TimeInterval = 45 * 60
    static let firstNightNudgeDelay: TimeInterval = 10 * 60

    // Tease the desktop
    static let mischiefIconCount = 6
    static let autoMischiefIconCount = 4
    static let autoMischiefMinimumGap: TimeInterval = 15 * 60
    static let autoMischiefMaximumGap: TimeInterval = 30 * 60
    static let autoTidyMinimumDelay: TimeInterval = 4 * 60
    static let autoTidyMaximumDelay: TimeInterval = 8 * 60
    static let autoTidyRetryDelay: TimeInterval = 90
    static let awayIdleTime: TimeInterval = 120
    static let fallbackDesktopIconSize: CGFloat = 64

    // Run across the desktop
    static let errandRunSpeed: CGFloat = 320
    static let errandCarrySpeed: CGFloat = 250
    static let errandAnimationRate: Double = 2.0
    static let errandLiftDuration: TimeInterval = 0.35
    static let errandLowerDuration: TimeInterval = 0.3
    static let errandTossPause: TimeInterval = 0.3
    static let errandTimeLimit: TimeInterval = 150
    static let errandTidyLimit = 8
    static let errandStraightDistance: CGFloat = 140
    static let errandSingleBendDistance: CGFloat = 380
    static let errandBendOffset: ClosedRange<CGFloat> = 50...130
    static let errandFetchReach: ClosedRange<CGFloat> = 180...480
    static let errandCarryReach: ClosedRange<CGFloat> = 260...600
    static let errandEdgeMargin: CGFloat = 70
    static let errandChestHeight: CGFloat = 0.45
    static let errandCarryGap: CGFloat = 22
    static let errandIconSendInterval: TimeInterval = 0.05
    static let errandSendFailureLimit = 3
    static let errandWindowScanInterval: TimeInterval = 0.3

    // Clear the windows away for a trip asked for from the menu
    static let curtainLingerAfterMess: TimeInterval = 2.5
    static let curtainLingerAfterTidy: TimeInterval = 1.5
    static let visibleDesktopCoverageLimit: CGFloat = 0.5
    static let coverageGridColumns = 16
    static let coverageGridRows = 10

    // Filter windows
    static let minimumWindowWidth: CGFloat = 220
    static let minimumWindowHeight: CGFloat = 120
    static let minimumLedgeWidth: CGFloat = 90
    static let minimumLedgeRise: CGFloat = 40

    // Time the agent states
    static let reviewDuration: TimeInterval = 40
    static let runningTimeout: TimeInterval = 30 * 60
    static let sessionExpiry: TimeInterval = 6 * 60 * 60
    static let attentionWaveInterval: TimeInterval = 6
    static let workingPoseDuration: TimeInterval = 4
    static let runningListTimeout: TimeInterval = 2 * 60 * 60
    static let interruptQuietTime: TimeInterval = 5
    static let interruptCheckInterval: TimeInterval = 5
    static let transcriptTailBytes: UInt64 = 32 * 1024
    static let boardRowLimit = 5
    static let titleRetryInterval: TimeInterval = 30
    static let boardTitleWidth = 32
    static let claudeJumpDelay: TimeInterval = 0.5
    static let eventsFileLimit: UInt64 = 256 * 1024
}

/// Says which spritesheet rows the two walking clips are made from.
enum WalkRowLayout: String, CaseIterable {
    case asDrawn = "plain"
    case swapped = "swapped"
    case rightMirrored = "mirrored"

    /// Gives the menu title of the choice.
    var title: String {
        switch self {
        case .asDrawn:
            return "As Drawn"
        case .swapped:
            return "Swap Left and Right Rows"
        case .rightMirrored:
            return "Mirror the Right Row for Left"
        }
    }
}

/// Reads and saves the choices kept for each pet.
enum PetPreferences {
    /// Gives the walking row layout chosen for a pet, or its default.
    static func walkRowLayout(identifier: String) -> WalkRowLayout {
        // Use the saved choice
        let stored = UserDefaults.standard.dictionary(forKey: PetConfig.walkRowLayoutKey) as? [String: String]
        if let rawValue = stored?[identifier], let layout = WalkRowLayout(rawValue: rawValue) {
            return layout
        }

        // Fall back on the older swap switch, then on the default
        let storedSwaps = UserDefaults.standard.dictionary(forKey: PetConfig.runningRowSwapKey) as? [String: Bool]
        if let swapsRunningRows = storedSwaps?[identifier] {
            return swapsRunningRows ? .swapped : .asDrawn
        }
        return PetConfig.defaultWalkRowLayouts[identifier] ?? .asDrawn
    }

    /// Saves the walking row layout chosen for a pet.
    static func setWalkRowLayout(_ layout: WalkRowLayout, identifier: String) {
        var stored = UserDefaults.standard.dictionary(forKey: PetConfig.walkRowLayoutKey) as? [String: String] ?? [:]
        stored[identifier] = layout.rawValue
        UserDefaults.standard.set(stored, forKey: PetConfig.walkRowLayoutKey)
    }
}
