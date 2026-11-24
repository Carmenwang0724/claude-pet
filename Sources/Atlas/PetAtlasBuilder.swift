import Accelerate
import AppKit
import ImageIO

/// Names one row of the Codex pet atlas and its frame timing.
private struct ClipLayout {
    let name: String
    let row: Int
    let durations: [TimeInterval]
}

/// Records the opaque area found inside one atlas cell.
private struct CellBounds {
    let minimumX: Int
    let maximumX: Int
    let minimumY: Int
    let maximumY: Int
    let isClipped: Bool
}

/// Points at the pixels of the whole atlas while it is being cut.
private struct AtlasPixels {
    let base: UnsafePointer<UInt8>
    let rowBytes: Int
    let cellWidth: Int
    let cellHeight: Int

    /// Reads the opacity of one pixel of a cell.
    func alpha(originX: Int, originY: Int, x: Int, y: Int) -> UInt8 {
        return base[(originY + y) * rowBytes + (originX + x) * 4 + 3]
    }
}

/// Keeps one row of the atlas while the clips are being built.
private struct CutRow {
    let clip: AnimationClip
    let rawFrames: [Data]
    let clippedFrameCount: Int
    let bounds: [CellBounds]
}

/// Cuts a pet's atlas into clips and stores them on disk for the app to map.
enum PetAtlasBuilder {
    private static let layouts: [ClipLayout] = [
        ClipLayout(name: "idle", row: 0, durations: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]),
        ClipLayout(name: "running-right", row: 1, durations: uniformDurations(count: 8, each: 0.12, last: 0.22)),
        ClipLayout(name: "running-left", row: 2, durations: uniformDurations(count: 8, each: 0.12, last: 0.22)),
        ClipLayout(name: "waving", row: 3, durations: uniformDurations(count: 4, each: 0.14, last: 0.28)),
        ClipLayout(name: "jumping", row: 4, durations: uniformDurations(count: 5, each: 0.14, last: 0.28)),
        ClipLayout(name: "failed", row: 5, durations: uniformDurations(count: 8, each: 0.14, last: 0.24)),
        ClipLayout(name: "waiting", row: 6, durations: uniformDurations(count: 6, each: 0.15, last: 0.26)),
        ClipLayout(name: "running", row: 7, durations: uniformDurations(count: 6, each: 0.12, last: 0.22)),
        ClipLayout(name: "review", row: 8, durations: uniformDurations(count: 6, each: 0.15, last: 0.28)),
    ]

    /// Cuts an atlas from the command line and returns the exit status.
    static func run(petFolderPath: String, cacheFolderPath: String, swapsRunningRows: Bool) -> Int32 {
        do {
            try build(
                petFolder: URL(fileURLWithPath: petFolderPath, isDirectory: true),
                cacheFolder: URL(fileURLWithPath: cacheFolderPath, isDirectory: true),
                swapsRunningRows: swapsRunningRows
            )
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    /// Cuts the atlas of a pet folder and writes the clips into a cache folder.
    static func build(petFolder: URL, cacheFolder: URL, swapsRunningRows: Bool) throws {
        // Read the manifest
        let manifest = PetFolder.readManifest(folder: petFolder)

        // Decode the spritesheet
        let spritesheetURL = try PetFolder.locateSpritesheet(folder: petFolder, preferredName: manifest.spritesheetName)
        let image = try decodeImage(at: spritesheetURL)

        // Work out the grid
        let columns = PetConfig.atlasColumns
        guard image.width % columns == 0 else {
            throw PetAtlasError.invalidGrid(width: image.width, height: image.height)
        }
        let cellWidth = image.width / columns
        let estimatedRows = CGFloat(image.height) / (CGFloat(cellWidth) * PetConfig.referenceCellAspect)
        let rows = Int(estimatedRows.rounded())
        guard rows >= PetConfig.minimumAtlasRows, image.height % rows == 0 else {
            throw PetAtlasError.invalidGrid(width: image.width, height: image.height)
        }
        let cellHeight = image.height / rows

        // Expand the whole atlas into plain pixels once
        guard let pixelBuffer = makePixelBuffer(of: image) else {
            throw PetAtlasError.unreadableImage(path: spritesheetURL.path)
        }
        defer {
            pixelBuffer.free()
        }
        let pixels = AtlasPixels(
            base: UnsafePointer(pixelBuffer.data.assumingMemoryBound(to: UInt8.self)),
            rowBytes: pixelBuffer.rowBytes,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )

        // Cut each canonical row into a clip
        var cutRows: [String: CutRow] = [:]
        for layout in layouts {
            let atlasRowIndex = atlasRow(for: layout, swapsRunningRows: swapsRunningRows)
            if let cutRow = cutRow(layout: layout, atlasRowIndex: atlasRowIndex, pixels: pixels) {
                cutRows[layout.name] = cutRow
            }
        }
        guard let idleRow = cutRows["idle"] else {
            throw PetAtlasError.emptyIdleRow(path: spritesheetURL.path)
        }

        // Keep the clips shown as they are
        var clips: [AnimationClip] = []
        for layout in layouts where layout.name != "running-right" && layout.name != "running-left" {
            if let cutRow = cutRows[layout.name] {
                clips.append(cutRow.clip)
            }
        }

        // Build the walking and sleeping clips
        let walkingClips = makeWalkingClips(
            rightRow: cutRows["running-right"],
            leftRow: cutRows["running-left"],
            idleClip: idleRow.clip,
            pixels: pixels
        )
        clips.append(walkingClips.right)
        clips.append(walkingClips.left)
        clips.append(makeSleepingClip(failedClip: cutRows["failed"]?.clip, idleClip: idleRow.clip))

        // Measure the empty margins around the body
        let lowestOpaqueRow = idleRow.bounds.map { $0.maximumY }.max() ?? cellHeight - 1
        let highestOpaqueRow = idleRow.bounds.map { $0.minimumY }.min() ?? 0

        // Store the result
        let block = PetConfig.maskBlockPixels
        try write(
            clips: clips,
            displayName: manifest.displayName,
            cellSize: (cellWidth, cellHeight),
            insets: (cellHeight - 1 - lowestOpaqueRow, highestOpaqueRow),
            maskSize: (cellWidth / block, cellHeight / block),
            cacheFolder: cacheFolder,
            identifier: manifest.identifier
        )
    }

    // MARK: - Reading

    /// Returns the atlas row a clip is cut from.
    private static func atlasRow(for layout: ClipLayout, swapsRunningRows: Bool) -> Int {
        let partnerNames = ["running-right": "running-left", "running-left": "running-right"]
        guard swapsRunningRows, let partnerName = partnerNames[layout.name] else {
            return layout.row
        }
        let partner = layouts.first { $0.name == partnerName }
        return partner?.row ?? layout.row
    }

    /// Builds a duration list that holds the last frame longer.
    private static func uniformDurations(count: Int, each: TimeInterval, last: TimeInterval) -> [TimeInterval] {
        var durations = [TimeInterval](repeating: each, count: count)
        durations[count - 1] = last
        return durations
    }

    /// Decodes an image file into a bitmap.
    private static func decodeImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PetAtlasError.unreadableImage(path: url.path)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetAtlasError.unreadableImage(path: url.path)
        }
        return image
    }

    /// Converts the atlas into plain RGBA pixels, top row first, without drawing it.
    private static func makePixelBuffer(of image: CGImage) -> vImage_Buffer? {
        let pixelFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let format = pixelFormat else {
            return nil
        }
        return try? vImage_Buffer(cgImage: image, format: format)
    }

    // MARK: - Cutting

    /// Cuts the frames of one atlas row, stopping at the first empty cell.
    private static func cutRow(layout: ClipLayout, atlasRowIndex: Int, pixels: AtlasPixels) -> CutRow? {
        var encodedFrames: [Data] = []
        var rawFrames: [Data] = []
        var masks: [FrameMask] = []
        var bounds: [CellBounds] = []
        var clippedFrameCount = 0
        let originY = atlasRowIndex * pixels.cellHeight
        for column in 0..<layout.durations.count {
            // Stop at the first empty cell
            let originX = column * pixels.cellWidth
            guard let cellBounds = measureCell(pixels: pixels, originX: originX, originY: originY) else {
                break
            }

            // Copy and compress the cell
            let rawFrame = copyCell(pixels: pixels, originX: originX, originY: originY)
            guard let encodedFrame = encodeFrame(rawPixels: rawFrame, width: pixels.cellWidth, height: pixels.cellHeight) else {
                break
            }
            encodedFrames.append(encodedFrame)
            rawFrames.append(rawFrame)
            masks.append(makeMask(pixels: pixels, originX: originX, originY: originY))
            bounds.append(cellBounds)
            if cellBounds.isClipped {
                clippedFrameCount += 1
            }
        }
        guard !encodedFrames.isEmpty else {
            return nil
        }
        let clip = AnimationClip(
            name: layout.name,
            encodedFrames: encodedFrames,
            durations: Array(layout.durations.prefix(encodedFrames.count)),
            masks: masks
        )
        return CutRow(clip: clip, rawFrames: rawFrames, clippedFrameCount: clippedFrameCount, bounds: bounds)
    }

    /// Finds the opaque area of one cell, or nil when the cell is empty.
    private static func measureCell(pixels: AtlasPixels, originX: Int, originY: Int) -> CellBounds? {
        // Find the box around the opaque pixels
        let threshold = PetConfig.opaqueAlphaThreshold
        var minimumX = pixels.cellWidth
        var maximumX = -1
        var minimumY = pixels.cellHeight
        var maximumY = -1
        var opaquePixels = 0
        for y in 0..<pixels.cellHeight {
            for x in 0..<pixels.cellWidth where pixels.alpha(originX: originX, originY: originY, x: x, y: y) > threshold {
                opaquePixels += 1
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
            }
        }
        guard opaquePixels >= PetConfig.minimumOpaquePixels else {
            return nil
        }

        // Count the opaque pixels on the outermost columns of the body
        var leftRun = 0
        var rightRun = 0
        for y in minimumY...maximumY {
            if pixels.alpha(originX: originX, originY: originY, x: minimumX, y: y) > threshold {
                leftRun += 1
            }
            if pixels.alpha(originX: originX, originY: originY, x: maximumX, y: y) > threshold {
                rightRun += 1
            }
        }

        // Flag a body that ends in a long straight vertical cut
        let bodyHeight = maximumY - minimumY + 1
        let longestRun = max(leftRun, rightRun)
        let isClipped = longestRun >= PetConfig.minimumClippedRun && longestRun * 5 >= bodyHeight
        return CellBounds(
            minimumX: minimumX,
            maximumX: maximumX,
            minimumY: minimumY,
            maximumY: maximumY,
            isClipped: isClipped
        )
    }

    /// Copies the pixels of one cell out of the atlas.
    private static func copyCell(pixels: AtlasPixels, originX: Int, originY: Int) -> Data {
        var cell = Data(capacity: pixels.cellWidth * pixels.cellHeight * 4)
        for y in 0..<pixels.cellHeight {
            let rowStart = (originY + y) * pixels.rowBytes + originX * 4
            cell.append(pixels.base + rowStart, count: pixels.cellWidth * 4)
        }
        return cell
    }

    /// Reduces one cell to a coarse opacity grid.
    private static func makeMask(pixels: AtlasPixels, originX: Int, originY: Int) -> FrameMask {
        let block = PetConfig.maskBlockPixels
        let maskColumns = pixels.cellWidth / block
        let maskRows = pixels.cellHeight / block
        var cells = [Bool](repeating: false, count: maskColumns * maskRows)
        for maskRow in 0..<maskRows {
            for maskColumn in 0..<maskColumns {
                var isOpaque = false
                for y in 0..<block {
                    for x in 0..<block {
                        let alpha = pixels.alpha(
                            originX: originX,
                            originY: originY,
                            x: maskColumn * block + x,
                            y: maskRow * block + y
                        )
                        if alpha > PetConfig.opaqueAlphaThreshold {
                            isOpaque = true
                        }
                    }
                }
                cells[maskRow * maskColumns + maskColumn] = isOpaque
            }
        }
        return FrameMask(columns: maskColumns, rows: maskRows, cells: cells)
    }

    // MARK: - Derived clips

    /// Chooses the cleaner source row for each walking direction.
    private static func makeWalkingClips(
        rightRow: CutRow?,
        leftRow: CutRow?,
        idleClip: AnimationClip,
        pixels: AtlasPixels
    ) -> (right: AnimationClip, left: AnimationClip) {
        // Fall back to the idle frames when the atlas has no running rows
        guard let anyRow = rightRow ?? leftRow else {
            let right = AnimationClip(
                name: "walk-right",
                encodedFrames: idleClip.encodedFrames,
                durations: idleClip.durations,
                masks: idleClip.masks
            )
            let left = AnimationClip(
                name: "walk-left",
                encodedFrames: idleClip.encodedFrames,
                durations: idleClip.durations,
                masks: idleClip.masks
            )
            return (right, left)
        }
        let rightClippedCount = rightRow?.clippedFrameCount ?? 0
        let leftClippedCount = leftRow?.clippedFrameCount ?? 0

        // Pick the right-facing frames
        let right: AnimationClip
        if let rightRow = rightRow, rightClippedCount <= leftClippedCount || leftRow == nil {
            right = makeWalkClip(name: "walk-right", source: rightRow, isMirrored: false, pixels: pixels)
        } else {
            right = makeWalkClip(name: "walk-right", source: leftRow ?? anyRow, isMirrored: true, pixels: pixels)
        }

        // Pick the left-facing frames
        let left: AnimationClip
        if let leftRow = leftRow, leftClippedCount <= rightClippedCount || rightRow == nil {
            left = makeWalkClip(name: "walk-left", source: leftRow, isMirrored: false, pixels: pixels)
        } else {
            left = makeWalkClip(name: "walk-left", source: rightRow ?? anyRow, isMirrored: true, pixels: pixels)
        }
        return (right, left)
    }

    /// Copies a running row into an evenly paced walking clip, flipped when asked.
    private static func makeWalkClip(name: String, source: CutRow, isMirrored: Bool, pixels: AtlasPixels) -> AnimationClip {
        var encodedFrames: [Data] = []
        var masks: [FrameMask] = []
        for index in 0..<source.clip.frameCount {
            // Reuse the frame as it is when no flip is needed
            guard isMirrored else {
                encodedFrames.append(source.clip.encodedFrames[index])
                masks.append(source.clip.masks[index])
                continue
            }

            // Flip the pixels and compress them again
            let flippedPixels = mirrorPixels(source.rawFrames[index], width: pixels.cellWidth, height: pixels.cellHeight)
            let flippedFrame = encodeFrame(rawPixels: flippedPixels, width: pixels.cellWidth, height: pixels.cellHeight)
            encodedFrames.append(flippedFrame ?? source.clip.encodedFrames[index])
            masks.append(source.clip.masks[index].mirrored())
        }
        let durations = [TimeInterval](repeating: PetConfig.walkFrameDuration, count: encodedFrames.count)
        return AnimationClip(name: name, encodedFrames: encodedFrames, durations: durations, masks: masks)
    }

    /// Holds the middle frame of the failed row as a sleeping pose.
    private static func makeSleepingClip(failedClip: AnimationClip?, idleClip: AnimationClip) -> AnimationClip {
        let sourceClip = failedClip ?? idleClip
        let middleIndex = (sourceClip.frameCount - 1) / 2
        return AnimationClip(
            name: "sleeping",
            encodedFrames: [sourceClip.encodedFrames[middleIndex]],
            durations: [1.0],
            masks: [sourceClip.masks[middleIndex]]
        )
    }

    /// Flips the pixels of one frame left to right.
    private static func mirrorPixels(_ rawPixels: Data, width: Int, height: Int) -> Data {
        var flipped = [UInt8](repeating: 0, count: rawPixels.count)
        rawPixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let sourceStart = (y * width + x) * 4
                    let targetStart = (y * width + (width - 1 - x)) * 4
                    flipped[targetStart] = source[sourceStart]
                    flipped[targetStart + 1] = source[sourceStart + 1]
                    flipped[targetStart + 2] = source[sourceStart + 2]
                    flipped[targetStart + 3] = source[sourceStart + 3]
                }
            }
        }
        return Data(flipped)
    }

    /// Compresses the pixels of one frame as PNG data.
    private static func encodeFrame(rawPixels: Data, width: Int, height: Int) -> Data? {
        // Wrap the pixels as an image without drawing them
        guard let provider = CGDataProvider(data: rawPixels as CFData) else {
            return nil
        }
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
        guard let frameImage = image else {
            return nil
        }

        // Write the image as PNG into memory
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)
        guard let imageDestination = destination else {
            return nil
        }
        CGImageDestinationAddImage(imageDestination, frameImage, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            return nil
        }
        return encoded as Data
    }

    // MARK: - Writing

    /// Writes the frames and the description of every clip, then swaps the new folder into place.
    private static func write(
        clips: [AnimationClip],
        displayName: String,
        cellSize: (width: Int, height: Int),
        insets: (foot: Int, head: Int),
        maskSize: (columns: Int, rows: Int),
        cacheFolder: URL,
        identifier: String
    ) throws {
        // Start from an empty temporary folder next to the final one
        let fileManager = FileManager.default
        let parentFolder = cacheFolder.deletingLastPathComponent()
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let temporaryName = "building-\(processIdentifier)-\(cacheFolder.lastPathComponent)"
        let temporaryFolder = parentFolder.appendingPathComponent(temporaryName, isDirectory: true)
        try? fileManager.removeItem(at: temporaryFolder)
        try fileManager.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)

        // Write every frame and describe every clip
        var cachedClips: [CachedClip] = []
        for clip in clips {
            var frameFiles: [String] = []
            for index in 0..<clip.frameCount {
                let fileName = "\(clip.name)-\(index).png"
                try clip.encodedFrames[index].write(to: temporaryFolder.appendingPathComponent(fileName))
                frameFiles.append(fileName)
            }
            cachedClips.append(
                CachedClip(
                    name: clip.name,
                    durations: clip.durations,
                    frameFiles: frameFiles,
                    masks: clip.masks.map { PetAtlasCache.packMask($0) }
                )
            )
        }
        let cachedAtlas = CachedAtlas(
            displayName: displayName,
            cellWidth: cellSize.width,
            cellHeight: cellSize.height,
            footInset: insets.foot,
            headInset: insets.head,
            maskColumns: maskSize.columns,
            maskRows: maskSize.rows,
            clips: cachedClips
        )
        let cacheData = try JSONEncoder().encode(cachedAtlas)
        try cacheData.write(to: temporaryFolder.appendingPathComponent(PetAtlasCache.manifestName))

        // Remove the older cut atlases of this pet
        let prefix = PetAtlasCache.folderPrefix(identifier: identifier)
        let siblings = (try? fileManager.contentsOfDirectory(at: parentFolder, includingPropertiesForKeys: nil)) ?? []
        for sibling in siblings where sibling.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: sibling)
        }

        // Put the new cut atlas in place
        try fileManager.moveItem(at: temporaryFolder, to: cacheFolder)
    }
}
