import AppKit
import ImageIO

/// Explains why a pet folder could not be loaded.
enum PetAtlasError: Error, CustomStringConvertible {
    case missingSpritesheet(folder: String)
    case unreadableImage(path: String)
    case invalidGrid(width: Int, height: Int)
    case emptyIdleRow(path: String)
    case builderFailed(status: Int32)
    case unreadableCache(folder: String)

    var description: String {
        switch self {
        case .missingSpritesheet(let folder):
            return "No spritesheet found in \(folder)"
        case .unreadableImage(let path):
            return "Could not decode the image at \(path)"
        case .invalidGrid(let width, let height):
            return "Atlas size \(width)x\(height) does not fit an 8-column pet grid"
        case .emptyIdleRow(let path):
            return "The idle row of \(path) has no frames"
        case .builderFailed(let status):
            return "Cutting the atlas failed with status \(status)"
        case .unreadableCache(let folder):
            return "Could not read the cut atlas in \(folder)"
        }
    }
}

/// Stores a coarse opacity grid of one frame.
struct FrameMask {
    let columns: Int
    let rows: Int
    let cells: [Bool]

    /// Reports whether the frame is opaque at a point measured from its top-left corner.
    func isOpaque(normalizedX: CGFloat, normalizedY: CGFloat) -> Bool {
        let column = Int(normalizedX * CGFloat(columns))
        let row = Int(normalizedY * CGFloat(rows))
        guard column >= 0, column < columns, row >= 0, row < rows else {
            return false
        }
        return cells[row * columns + column]
    }

    /// Returns the mask flipped left to right.
    func mirrored() -> FrameMask {
        var flippedCells = [Bool](repeating: false, count: cells.count)
        for row in 0..<rows {
            for column in 0..<columns {
                flippedCells[row * columns + column] = cells[row * columns + (columns - 1 - column)]
            }
        }
        return FrameMask(columns: columns, rows: rows, cells: flippedCells)
    }
}

/// Holds one named animation: its compressed frames, timing and opacity masks.
struct AnimationClip {
    let name: String
    let encodedFrames: [Data]
    let durations: [TimeInterval]
    let masks: [FrameMask]

    /// Gives the number of frames in the clip.
    var frameCount: Int {
        return encodedFrames.count
    }
}

/// Holds a pet's clips, read from the cut atlas kept on disk.
final class PetAtlas {
    let identifier: String
    let displayName: String
    let cellPixelSize: CGSize
    let footInsetPixels: CGFloat
    let headInsetPixels: CGFloat
    private let clips: [String: AnimationClip]
    private let idleClip: AnimationClip
    private var expandedFrames: [String: [CGImage]] = [:]
    private var expandedOrder: [String] = []

    private init(identifier: String, cachedAtlas: CachedAtlas, clips: [String: AnimationClip], idleClip: AnimationClip) {
        self.identifier = identifier
        self.displayName = cachedAtlas.displayName
        self.cellPixelSize = CGSize(width: cachedAtlas.cellWidth, height: cachedAtlas.cellHeight)
        self.footInsetPixels = CGFloat(cachedAtlas.footInset)
        self.headInsetPixels = CGFloat(cachedAtlas.headInset)
        self.clips = clips
        self.idleClip = idleClip
    }

    /// Lists the names of every clip in a stable order.
    var clipNames: [String] {
        return clips.keys.sorted()
    }

    /// Adds up the size of the compressed frames of every clip.
    var encodedByteCount: Int {
        var seenFrames: Set<Data> = []
        for clip in clips.values {
            seenFrames.formUnion(clip.encodedFrames)
        }
        return seenFrames.reduce(0) { $0 + $1.count }
    }

    /// Returns the clip with the given name, or the idle clip when it is absent.
    func clip(named name: String) -> AnimationClip {
        return clips[name] ?? idleClip
    }

    /// Returns the drawable frames of a clip, keeping only the most recently used clips expanded.
    func frames(forClipNamed name: String) -> [CGImage] {
        // Reuse the frames when the clip is already expanded
        let clip = clip(named: name)
        if let frames = expandedFrames[clip.name] {
            expandedOrder.removeAll { $0 == clip.name }
            expandedOrder.append(clip.name)
            return frames
        }

        // Expand the clip
        let frames = clip.encodedFrames.compactMap { PetAtlas.decodeFrame(data: $0) }
        expandedFrames[clip.name] = frames
        expandedOrder.append(clip.name)

        // Let go of the clip used longest ago
        while expandedOrder.count > PetConfig.expandedClipLimit {
            let oldestName = expandedOrder.removeFirst()
            expandedFrames[oldestName] = nil
        }
        return frames
    }

    // MARK: - Loading

    /// Loads the pet stored in a folder, cutting its atlas first when that has not been done yet.
    static func load(folder: URL, walkRowLayout: WalkRowLayout) throws -> PetAtlas {
        // Find the cut atlas that matches the pet folder as it is now
        let manifest = PetFolder.readManifest(folder: folder)
        let spritesheetURL = try PetFolder.locateSpritesheet(folder: folder, preferredName: manifest.spritesheetName)
        let cacheFolder = PetAtlasCache.folder(
            identifier: manifest.identifier,
            spritesheetURL: spritesheetURL,
            walkRowLayout: walkRowLayout
        )

        // Cut the atlas in a helper process when there is no cut atlas yet
        let cacheFileURL = cacheFolder.appendingPathComponent(PetAtlasCache.manifestName)
        if !FileManager.default.fileExists(atPath: cacheFileURL.path) {
            try runBuilder(petFolder: folder, cacheFolder: cacheFolder, walkRowLayout: walkRowLayout)
        }
        return try loadCutAtlas(identifier: manifest.identifier, cacheFolder: cacheFolder)
    }

    /// Runs this program again in its cutting mode and waits for it to finish.
    private static func runBuilder(petFolder: URL, cacheFolder: URL, walkRowLayout: WalkRowLayout) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw PetAtlasError.builderFailed(status: -1)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--build-cache", petFolder.path, cacheFolder.path, walkRowLayout.rawValue]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PetAtlasError.builderFailed(status: process.terminationStatus)
        }
    }

    /// Reads a cut atlas, mapping its frame files instead of copying them into memory.
    private static func loadCutAtlas(identifier: String, cacheFolder: URL) throws -> PetAtlas {
        // Read the description of the cut atlas
        let cacheFileURL = cacheFolder.appendingPathComponent(PetAtlasCache.manifestName)
        guard let cacheData = try? Data(contentsOf: cacheFileURL) else {
            throw PetAtlasError.unreadableCache(folder: cacheFolder.path)
        }
        guard let cachedAtlas = try? JSONDecoder().decode(CachedAtlas.self, from: cacheData) else {
            throw PetAtlasError.unreadableCache(folder: cacheFolder.path)
        }

        // Build each clip from its frame files and masks
        var clips: [String: AnimationClip] = [:]
        for cachedClip in cachedAtlas.clips {
            var encodedFrames: [Data] = []
            var masks: [FrameMask] = []
            for index in 0..<cachedClip.frameFiles.count {
                let frameURL = cacheFolder.appendingPathComponent(cachedClip.frameFiles[index])
                guard let frameData = try? Data(contentsOf: frameURL, options: [.alwaysMapped]) else {
                    throw PetAtlasError.unreadableCache(folder: cacheFolder.path)
                }
                let mask = PetAtlasCache.unpackMask(
                    cachedClip.masks[index],
                    columns: cachedAtlas.maskColumns,
                    rows: cachedAtlas.maskRows
                )
                guard let frameMask = mask else {
                    throw PetAtlasError.unreadableCache(folder: cacheFolder.path)
                }
                encodedFrames.append(frameData)
                masks.append(frameMask)
            }
            clips[cachedClip.name] = AnimationClip(
                name: cachedClip.name,
                encodedFrames: encodedFrames,
                durations: cachedClip.durations,
                masks: masks
            )
        }
        guard let idleClip = clips["idle"], idleClip.frameCount > 0 else {
            throw PetAtlasError.unreadableCache(folder: cacheFolder.path)
        }
        return PetAtlas(identifier: identifier, cachedAtlas: cachedAtlas, clips: clips, idleClip: idleClip)
    }

    /// Expands PNG data into a bitmap that is ready to draw.
    private static func decodeFrame(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// Describes one pet found on disk.
struct PetListing {
    let identifier: String
    let displayName: String
    let folder: URL
}

/// Finds the pets installed in the shared pet folders.
enum PetLibrary {
    /// Lists every installed pet, sorted by name.
    static func installedPets() -> [PetListing] {
        var listings: [PetListing] = []
        var seenIdentifiers: Set<String> = []
        for libraryFolder in PetConfig.petLibraryFolders {
            let contents = try? FileManager.default.contentsOfDirectory(
                at: libraryFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for folder in contents ?? [] {
                let identifier = folder.lastPathComponent
                let manifestPath = folder.appendingPathComponent("pet.json").path
                guard FileManager.default.fileExists(atPath: manifestPath) else {
                    continue
                }
                guard !seenIdentifiers.contains(identifier) else {
                    continue
                }
                seenIdentifiers.insert(identifier)
                let displayName = PetFolder.readManifest(folder: folder).displayName
                listings.append(PetListing(identifier: identifier, displayName: displayName, folder: folder))
            }
        }
        return listings.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// Finds one installed pet by its folder name.
    static func listing(identifier: String) -> PetListing? {
        return installedPets().first { $0.identifier == identifier }
    }
}
