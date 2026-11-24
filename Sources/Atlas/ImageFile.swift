import AppKit
import ImageIO

/// Saves bitmaps to disk.
enum ImageFile {
    /// Writes an image as a PNG file and reports whether it worked.
    static func writePNG(image: CGImage, to url: URL) -> Bool {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        guard let imageDestination = destination else {
            return false
        }
        CGImageDestinationAddImage(imageDestination, image, nil)
        return CGImageDestinationFinalize(imageDestination)
    }
}
