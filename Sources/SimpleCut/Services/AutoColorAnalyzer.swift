@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

enum AutoColorAnalyzer {
  private struct Accumulator {
    var luminance: [Double] = []
    var red = 0.0
    var blue = 0.0
    var chroma = 0.0
    var chromaCount = 0
  }

  static func analyze(clips: [VideoClip]) async throws -> ColorSettings {
    guard !clips.isEmpty else { return .neutral }
    var accumulator = Accumulator()
    let frameBudget = 12
    let framesPerClip = max(1, min(3, frameBudget / max(1, clips.count)))

    for clip in clips.prefix(frameBudget) {
      try Task.checkCancellation()
      let asset = AVURLAsset(url: clip.sourceURL)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 160, height: 160)
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

      for frameIndex in 0..<framesPerClip {
        try Task.checkCancellation()
        let fraction = Double(frameIndex + 1) / Double(framesPerClip + 1)
        let seconds = clip.sourceStart + clip.duration * fraction
        let result = try await generator.image(
          at: CMTime(seconds: seconds, preferredTimescale: 600)
        )
        accumulate(result.image, into: &accumulator)
      }
    }

    guard !accumulator.luminance.isEmpty else { return .neutral }
    return suggestedSettings(
      luminance: accumulator.luminance,
      red: accumulator.red,
      blue: accumulator.blue,
      averageChroma: accumulator.chroma
        / Double(max(1, accumulator.chromaCount))
    )
  }

  static func suggestedSettings(
    luminance: [Double],
    red: Double,
    blue: Double,
    averageChroma: Double
  ) -> ColorSettings {
    guard !luminance.isEmpty else { return .neutral }
    let sortedLuminance = luminance.sorted()
    let low = percentile(0.10, in: sortedLuminance)
    let median = percentile(0.50, in: sortedLuminance)
    let high = percentile(0.90, in: sortedLuminance)
    let span = max(0.12, high - low)
    let brightness = clamp((0.48 - median) * 0.38, -0.16, 0.16)
    let contrast = clamp(0.68 / span, 0.86, 1.24)
    let saturation = clamp(0.20 / max(averageChroma, 0.08), 0.92, 1.16)
    let channelTotal = max(0.001, red + blue)
    let redBlueCast = (red - blue) / channelTotal
    let warmth = clamp(-redBlueCast * 2.2, -0.45, 0.45)

    return ColorSettings(
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      warmth: warmth
    )
  }

  private static func accumulate(
    _ image: CGImage,
    into accumulator: inout Accumulator
  ) {
    let width = 64
    let height = 64
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(
        data: bytes.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    for index in stride(from: 0, to: pixels.count, by: 4) {
      let red = Double(pixels[index]) / 255
      let green = Double(pixels[index + 1]) / 255
      let blue = Double(pixels[index + 2]) / 255
      let maximum = max(red, green, blue)
      let minimum = min(red, green, blue)
      let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
      accumulator.luminance.append(luminance)
      accumulator.chroma += maximum - minimum
      accumulator.chromaCount += 1

      // Estimate white balance from mid-tone, relatively unsaturated pixels.
      // This avoids treating vivid objects and clipped highlights as a cast.
      if luminance > 0.15, luminance < 0.88, maximum - minimum < 0.22 {
        accumulator.red += red
        accumulator.blue += blue
      }
    }
  }

  private static func percentile(_ value: Double, in sorted: [Double]) -> Double {
    let index = min(
      sorted.count - 1,
      max(0, Int((Double(sorted.count - 1) * value).rounded()))
    )
    return sorted[index]
  }

  private static func clamp(
    _ value: Double,
    _ lower: Double,
    _ upper: Double
  ) -> Double {
    min(upper, max(lower, value))
  }
}
