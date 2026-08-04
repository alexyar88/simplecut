@preconcurrency import AVFoundation
import AppKit
import QuartzCore

enum ExportService {
  static func export(
    clips: [VideoClip],
    overlays: [OverlayItem],
    canvas: CanvasPreset,
    to destination: URL
  ) async throws {
    let built = try await CompositionBuilder.build(
      clips: clips,
      canvas: canvas
    )
    let videoComposition = built.videoComposition
    applyOverlays(
      overlays,
      canvas: canvas,
      duration: clips.reduce(0) { $0 + $1.duration },
      to: videoComposition
    )

    guard
      let session = AVAssetExportSession(
        asset: built.asset,
        presetName: AVAssetExportPresetHighestQuality
      )
    else {
      throw EditorError.exportFailed
    }
    session.videoComposition = videoComposition
    session.outputURL = destination
    session.outputFileType = .mp4
    await session.export()
    guard session.status == .completed else {
      throw session.error ?? EditorError.exportFailed
    }
  }

  private static func applyOverlays(
    _ overlays: [OverlayItem],
    canvas: CanvasPreset,
    duration: Double,
    to videoComposition: AVMutableVideoComposition
  ) {
    let parent = CALayer()
    let video = CALayer()
    let frame = CGRect(origin: .zero, size: canvas.size)
    parent.frame = frame
    video.frame = frame
    parent.addSublayer(video)

    for item in overlays {
      let layer: CALayer
      switch item.kind {
      case .text, .caption:
        let text = CATextLayer()
        text.string = item.text ?? ""
        text.alignmentMode = .center
        text.fontSize = item.fontSize
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

      let width = canvas.size.width * item.normalizedWidth
      let height =
        item.kind.isTextual
        ? max(item.fontSize * 1.8, 90)
        : width
      layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
      layer.position = CGPoint(
        x: canvas.size.width * item.normalizedX,
        y: canvas.size.height * (1 - item.normalizedY)
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
