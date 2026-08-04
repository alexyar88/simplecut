@preconcurrency import AVFoundation
import AppKit
import CoreImage
import QuartzCore

enum ExportService {
  static func export(
    clips: [VideoClip],
    overlays: [OverlayItem],
    canvas: CanvasPreset,
    audio: AudioSettings = AudioSettings(),
    color: ColorSettings = ColorSettings(),
    settings: ExportSettings = ExportSettings(),
    progress: @MainActor @escaping (Double) -> Void = { _ in },
    to destination: URL
  ) async throws {
    try validateDestination(
      destination,
      duration: clips.reduce(0) { $0 + $1.duration },
      settings: settings
    )
    await progress(0.02)
    let processedAudio = try await AudioProcessingService.process(
      clips: clips,
      settings: audio
    )
    defer {
      if let processedAudio {
        try? FileManager.default.removeItem(at: processedAudio.url)
      }
    }
    await progress(0.18)
    let outputSize = settings.outputSize(for: canvas)
    let built = try await CompositionBuilder.build(
      clips: clips,
      canvas: canvas,
      outputSize: outputSize,
      replacementAudioURL: processedAudio?.url
    )
    let videoComposition = built.videoComposition
    videoComposition.frameDuration = CMTime(
      value: 1,
      timescale: CMTimeScale(settings.framesPerSecond)
    )
    applyOverlays(
      overlays,
      canvasSize: outputSize,
      duration: clips.reduce(0) { $0 + $1.duration },
      color: color,
      to: videoComposition
    )

    guard
      let session = AVAssetExportSession(
        asset: built.asset,
        presetName: presetName(for: settings.quality)
      )
    else {
      throw EditorError.exportFailed
    }
    session.videoComposition = videoComposition
    session.outputURL = destination
    session.outputFileType = .mp4
    let sessionBox = ExportSessionBox(session)
    let exportTask = Task {
      await sessionBox.session.export()
    }
    do {
      while true {
        try Task.checkCancellation()
        let status = sessionBox.session.status
        if status == .completed || status == .failed || status == .cancelled {
          break
        }
        await progress(0.2 + Double(sessionBox.session.progress) * 0.8)
        try await Task.sleep(for: .milliseconds(100))
      }
      await exportTask.value
    } catch {
      sessionBox.session.cancelExport()
      exportTask.cancel()
      throw error
    }
    guard session.status == .completed else {
      throw session.error ?? EditorError.exportFailed
    }
    await progress(1)
  }

  private static func applyOverlays(
    _ overlays: [OverlayItem],
    canvasSize: CGSize,
    duration: Double,
    color: ColorSettings,
    to videoComposition: AVMutableVideoComposition
  ) {
    let parent = CALayer()
    let video = CALayer()
    let frame = CGRect(origin: .zero, size: canvasSize)
    parent.frame = frame
    video.frame = frame
    if !color.isNeutral {
      let controls = CIFilter(name: "CIColorControls")
      controls?.setValue(color.brightness, forKey: kCIInputBrightnessKey)
      controls?.setValue(color.contrast, forKey: kCIInputContrastKey)
      controls?.setValue(color.saturation, forKey: kCIInputSaturationKey)
      let temperature = CIFilter(name: "CITemperatureAndTint")
      temperature?.setValue(
        CIVector(x: 6_500, y: 0),
        forKey: "inputNeutral"
      )
      temperature?.setValue(
        CIVector(x: 6_500 + color.warmth * 1_500, y: 0),
        forKey: "inputTargetNeutral"
      )
      video.filters = [controls, temperature].compactMap { $0 }
    }
    parent.addSublayer(video)

    for item in overlays {
      let layer: CALayer
      switch item.kind {
      case .text, .caption:
        let text = CATextLayer()
        text.string = item.text ?? ""
        text.alignmentMode = .center
        text.fontSize = item.fontSize * canvasSize.width / 1_080
        text.foregroundColor = NSColor(hex: item.foregroundHex).cgColor
        text.backgroundColor = NSColor(hex: item.backgroundHex).cgColor
        text.cornerRadius = 14
        text.contentsScale = 2
        layer = text
      case .image:
        let image = item.imageURL.flatMap(NSImage.init(contentsOf:))
        let imageLayer = CALayer()
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect
        layer = imageLayer
      }

      let width = canvasSize.width * item.normalizedWidth
      let height =
        item.kind.isTextual
        ? max(
          item.fontSize * canvasSize.width / 1_080 * 1.8,
          90 * canvasSize.width / 1_080
        )
        : width
      layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
      layer.position = CGPoint(
        x: canvasSize.width * item.normalizedX,
        y: canvasSize.height * (1 - item.normalizedY)
      )
      layer.opacity = Float(item.opacity)
      layer.setAffineTransform(
        CGAffineTransform(rotationAngle: item.rotation * .pi / 180)
      )

      layer.opacity = 0
      let visibility = CAKeyframeAnimation(keyPath: "opacity")
      let safeDuration = max(duration, 0.01)
      let start = min(max(item.startTime / safeDuration, 0), 1)
      let end = min(
        max((item.startTime + item.duration) / safeDuration, start),
        1
      )
      visibility.values = [0, item.opacity, item.opacity, 0]
      visibility.keyTimes = [
        0,
        NSNumber(value: start),
        NSNumber(value: end),
        1,
      ]
      visibility.duration = safeDuration
      visibility.beginTime = AVCoreAnimationBeginTimeAtZero
      visibility.isRemovedOnCompletion = false
      layer.add(visibility, forKey: "visibility")
      parent.addSublayer(layer)
    }

    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: video,
      in: parent
    )
  }

  private static func presetName(for quality: ExportQuality) -> String {
    switch quality {
    case .compatible:
      AVAssetExportPresetHighestQuality
    case .efficient:
      AVAssetExportPresetHEVCHighestQuality
    case .compact:
      AVAssetExportPresetMediumQuality
    }
  }

  private static func validateDestination(
    _ destination: URL,
    duration: Double,
    settings: ExportSettings
  ) throws {
    let values = try destination.deletingLastPathComponent()
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let available = values.volumeAvailableCapacityForImportantUsage else {
      return
    }
    let pixels = settings.outputSize(for: .horizontal).width
      * settings.outputSize(for: .horizontal).height
    let estimatedBitrate =
      pixels * Double(settings.framesPerSecond)
      * (settings.quality == .compact ? 0.035 : 0.08)
    let estimatedBytes = Int64(max(20_000_000, duration * estimatedBitrate / 8))
    guard available > estimatedBytes * 2 else {
      throw ExportError.insufficientDiskSpace
    }
  }
}

private final class ExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}

enum ExportError: LocalizedError {
  case insufficientDiskSpace

  var errorDescription: String? {
    switch self {
    case .insufficientDiskSpace:
      "Недостаточно свободного места для экспорта"
    }
  }
}

extension NSColor {
  convenience init(hex: String) {
    let value = hex.trimmingCharacters(
      in: CharacterSet.alphanumerics.inverted
    )
    var number: UInt64 = 0
    Scanner(string: value).scanHexInt64(&number)
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    switch value.count {
    case 8:
      red = CGFloat((number >> 24) & 0xFF) / 255
      green = CGFloat((number >> 16) & 0xFF) / 255
      blue = CGFloat((number >> 8) & 0xFF) / 255
      alpha = CGFloat(number & 0xFF) / 255
    default:
      red = CGFloat((number >> 16) & 0xFF) / 255
      green = CGFloat((number >> 8) & 0xFF) / 255
      blue = CGFloat(number & 0xFF) / 255
      alpha = 1
    }
    self.init(
      calibratedRed: red,
      green: green,
      blue: blue,
      alpha: alpha
    )
  }
}
