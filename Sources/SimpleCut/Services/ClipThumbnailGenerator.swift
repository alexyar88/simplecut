@preconcurrency import AVFoundation
import AppKit

enum ClipThumbnailGenerator {
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
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero

      return (0..<count).compactMap { index in
        let fraction = (Double(index) + 0.5) / Double(count)
        let seconds =
          clip.sourceStart + min(
            max(0, clip.duration - 0.001),
            clip.duration * fraction
          )
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? generator.copyCGImage(at: time, actualTime: nil)
      }
    }.value
  }
}
