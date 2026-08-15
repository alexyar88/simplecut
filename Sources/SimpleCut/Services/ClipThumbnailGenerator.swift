@preconcurrency import AVFoundation
import AppKit

private final class ThumbnailCacheEntry {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}

private final class ThumbnailCache: @unchecked Sendable {
  let storage: NSCache<NSString, ThumbnailCacheEntry> = {
    let cache = NSCache<NSString, ThumbnailCacheEntry>()
    cache.countLimit = 800
    cache.totalCostLimit = 128 * 1_024 * 1_024
    return cache
  }()
}

enum ClipThumbnailGenerator {
  private static let cache = ThumbnailCache()

  static func images(
    for clip: VideoClip,
    count: Int,
    height: CGFloat
  ) async -> [CGImage] {
    guard count > 0, clip.duration > 0 else { return [] }

    return await Task.detached(priority: .utility) {
      let asset = AVURLAsset(url: clip.sourceURL)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(
        width: max(80, height * 16 / 9),
        height: max(40, height * 2)
      )
      let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
      generator.requestedTimeToleranceBefore = tolerance
      generator.requestedTimeToleranceAfter = tolerance

      return (0..<count).compactMap { index in
        guard !Task.isCancelled else { return nil }
        let fraction = (Double(index) + 0.5) / Double(count)
        let seconds =
          clip.sourceStart + min(
            max(0, clip.duration - 0.001),
            clip.duration * fraction
          )
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let key = cacheKey(url: clip.sourceURL, seconds: seconds, height: height)
        if let cached = cache.storage.object(forKey: key) {
          return cached.image
        }
        guard let image = try? generator.copyCGImage(at: time, actualTime: nil)
        else { return nil }
        cache.storage.setObject(
          ThumbnailCacheEntry(image),
          forKey: key,
          cost: image.bytesPerRow * image.height
        )
        return image
      }
    }.value
  }

  private static func cacheKey(
    url: URL,
    seconds: Double,
    height: CGFloat
  ) -> NSString {
    let quantizedTime = (seconds * 600).rounded() / 600
    return "\(url.path)|\(quantizedTime)|\(height)" as NSString
  }
}
