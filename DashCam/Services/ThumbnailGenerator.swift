import AVFoundation
import UIKit

/// Generates and caches library thumbnails off the main thread.
final class ThumbnailGenerator {
    private let cache = NSCache<NSString, UIImage>()

    /// Drops every cached thumbnail; they regenerate on demand.
    func clearCache() {
        cache.removeAllObjects()
    }

    func thumbnail(for url: URL) async -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}
