import AppKit
import ImageIO

/// Explains why the contact sheet could not be written.
enum AtlasDumpError: Error, CustomStringConvertible {
    case cannotDraw
    case cannotWrite(path: String)

    var description: String {
        switch self {
        case .cannotDraw:
            return "Could not create the drawing context"
        case .cannotWrite(let path):
            return "Could not write the image to \(path)"
        }
    }
}

/// Writes a contact sheet of a pet's clips for checking how the atlas was cut.
enum AtlasDump {
    private static let clipOrder = [
        "idle", "walk-right", "walk-left", "waving", "jumping", "failed", "waiting", "running", "review", "sleeping",
    ]
    private static let sheetScale: CGFloat = 0.5

    /// Loads a pet folder, prints its clips, and saves the contact sheet.
    static func run(petFolderPath: String, outputPath: String) -> Int32 {
        do {
            let folder = URL(fileURLWithPath: petFolderPath, isDirectory: true)
            let swapsRunningRows = PetPreferences.swapsRunningRows(identifier: folder.lastPathComponent)
            let atlas = try PetAtlas.load(folder: folder, swapsRunningRows: swapsRunningRows)
            printSummary(atlas: atlas)
            printMask(atlas: atlas)
            try writeContactSheet(atlas: atlas, outputURL: URL(fileURLWithPath: outputPath))
            print("contact sheet: \(outputPath)")
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    /// Prints the size of the cells and the length of every clip.
    private static func printSummary(atlas: PetAtlas) {
        print("pet: \(atlas.identifier) (\(atlas.displayName))")
        print("cell: \(Int(atlas.cellPixelSize.width))x\(Int(atlas.cellPixelSize.height))")
        print("foot inset: \(Int(atlas.footInsetPixels))  head inset: \(Int(atlas.headInsetPixels))")
        print("compressed frames: \(atlas.encodedByteCount / 1024) KB")
        for name in clipOrder {
            let clip = atlas.clip(named: name)
            let totalDuration = clip.durations.reduce(0, +)
            let paddedName = name.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("clip \(paddedName) frames \(clip.frameCount)  cycle \(String(format: "%.2f", totalDuration)) s")
        }
    }

    /// Prints the opacity grid of the first idle frame.
    private static func printMask(atlas: PetAtlas) {
        guard let mask = atlas.clip(named: "idle").masks.first else {
            return
        }
        for row in stride(from: 0, to: mask.rows, by: 2) {
            var line = ""
            for column in 0..<mask.columns {
                line += mask.cells[row * mask.columns + column] ? "#" : "."
            }
            print(line)
        }
    }

    /// Draws every clip as one row of frames with the foot and head lines marked.
    private static func writeContactSheet(atlas: PetAtlas, outputURL: URL) throws {
        // Size the sheet
        let frameWidth = Int(atlas.cellPixelSize.width * sheetScale)
        let frameHeight = Int(atlas.cellPixelSize.height * sheetScale)
        let sheetWidth = frameWidth * PetConfig.atlasColumns
        let sheetHeight = frameHeight * clipOrder.count
        let context = CGContext(
            data: nil,
            width: sheetWidth,
            height: sheetHeight,
            bitsPerComponent: 8,
            bytesPerRow: sheetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let sheet = context else {
            throw AtlasDumpError.cannotDraw
        }

        // Paint the background
        sheet.setFillColor(CGColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

        // Draw the clips from top to bottom
        for rowIndex in 0..<clipOrder.count {
            let frames = atlas.frames(forClipNamed: clipOrder[rowIndex])
            let rowBottom = sheetHeight - (rowIndex + 1) * frameHeight
            for frameIndex in 0..<frames.count {
                let frameRect = CGRect(x: frameIndex * frameWidth, y: rowBottom, width: frameWidth, height: frameHeight)
                sheet.draw(frames[frameIndex], in: frameRect)
            }

            // Mark the foot line in red
            let footY = CGFloat(rowBottom) + atlas.footInsetPixels * sheetScale
            sheet.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.8))
            sheet.fill(CGRect(x: 0, y: footY, width: CGFloat(sheetWidth), height: 1))

            // Mark the head line in blue
            let headY = CGFloat(rowBottom + frameHeight) - atlas.headInsetPixels * sheetScale
            sheet.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 0.8))
            sheet.fill(CGRect(x: 0, y: headY, width: CGFloat(sheetWidth), height: 1))
        }

        // Save the sheet as a PNG file
        guard let image = sheet.makeImage() else {
            throw AtlasDumpError.cannotDraw
        }
        let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
        guard let imageDestination = destination else {
            throw AtlasDumpError.cannotWrite(path: outputURL.path)
        }
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw AtlasDumpError.cannotWrite(path: outputURL.path)
        }
    }
}
