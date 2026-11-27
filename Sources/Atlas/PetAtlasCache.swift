import Foundation

/// Carries the fields read from pet.json.
struct PetManifest {
    let identifier: String
    let displayName: String
    let spritesheetName: String?
}

/// Reads the files of a pet folder.
enum PetFolder {
    /// Reads pet.json, falling back to the folder name.
    static func readManifest(folder: URL) -> PetManifest {
        let folderName = folder.lastPathComponent
        let manifestURL = folder.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return PetManifest(identifier: folderName, displayName: folderName, spritesheetName: nil)
        }
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return PetManifest(identifier: folderName, displayName: folderName, spritesheetName: nil)
        }
        let displayName = fields["displayName"] as? String ?? folderName
        let declaredPath = fields["spritesheetPath"] as? String
        let spritesheetName = declaredPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        return PetManifest(identifier: folderName, displayName: displayName, spritesheetName: spritesheetName)
    }

    /// Finds the spritesheet file inside the pet folder.
    static func locateSpritesheet(folder: URL, preferredName: String?) throws -> URL {
        var candidateNames: [String] = []
        if let preferredName = preferredName {
            candidateNames.append(preferredName)
        }
        candidateNames.append(contentsOf: ["spritesheet.webp", "spritesheet.png", "sprite.webp", "sprite.png"])
        for name in candidateNames {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw PetAtlasError.missingSpritesheet(folder: folder.path)
    }
}

/// Describes one clip of a cut atlas stored on disk.
struct CachedClip: Codable {
    let name: String
    let durations: [TimeInterval]
    let frameFiles: [String]
    let masks: [String]
}

/// Describes a cut atlas stored on disk.
struct CachedAtlas: Codable {
    let displayName: String
    let cellWidth: Int
    let cellHeight: Int
    let footInset: Int
    let headInset: Int
    let maskColumns: Int
    let maskRows: Int
    let clips: [CachedClip]
}

/// Names the folders that hold cut atlases and packs their masks.
enum PetAtlasCache {
    static let manifestName = "atlas.json"

    /// Returns the folder for the cut atlas of a spritesheet as it is now.
    static func folder(identifier: String, spritesheetURL: URL, walkRowLayout: WalkRowLayout) -> URL {
        // Read the size and date of the spritesheet
        let attributes = try? FileManager.default.attributesOfItem(atPath: spritesheetURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date
        let modificationStamp = Int(modificationDate?.timeIntervalSince1970 ?? 0)

        // Name the folder after everything the cut depends on
        let rowOrder = walkRowLayout.rawValue
        let version = PetConfig.atlasCacheVersion
        let folderName = "\(folderPrefix(identifier: identifier))v\(version)-\(rowOrder)-\(fileSize)-\(modificationStamp)"
        return PetConfig.atlasCacheDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Gives the start shared by every cut atlas folder of one pet.
    static func folderPrefix(identifier: String) -> String {
        return "\(identifier)--"
    }

    /// Packs the cells of a mask into a short text.
    static func packMask(_ mask: FrameMask) -> String {
        var bytes = [UInt8](repeating: 0, count: (mask.cells.count + 7) / 8)
        for index in 0..<mask.cells.count where mask.cells[index] {
            bytes[index / 8] |= UInt8(1) << UInt8(index % 8)
        }
        return Data(bytes).base64EncodedString()
    }

    /// Unpacks a mask written by packMask.
    static func unpackMask(_ text: String, columns: Int, rows: Int) -> FrameMask? {
        guard let data = Data(base64Encoded: text) else {
            return nil
        }
        let cellCount = columns * rows
        guard data.count * 8 >= cellCount else {
            return nil
        }
        let bytes = [UInt8](data)
        var cells = [Bool](repeating: false, count: cellCount)
        for index in 0..<cellCount {
            let bit = UInt8(1) << UInt8(index % 8)
            cells[index] = bytes[index / 8] & bit != 0
        }
        return FrameMask(columns: columns, rows: rows, cells: cells)
    }
}
