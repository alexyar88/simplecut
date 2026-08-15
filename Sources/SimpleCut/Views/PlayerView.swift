@preconcurrency import AVFoundation
import SwiftUI

struct PlayerView: NSViewRepresentable {
  let player: AVPlayer
  let scalingMode: VideoScalingMode
  let color: ColorSettings

  func makeNSView(context: Context) -> PlayerContainerView {
    let view = PlayerContainerView()
    view.update(player: player, scalingMode: scalingMode, color: color)
    return view
  }

  func updateNSView(_ nsView: PlayerContainerView, context: Context) {
    nsView.update(player: player, scalingMode: scalingMode, color: color)
  }
}

final class PlayerContainerView: NSView {
  let playerLayer = AVPlayerLayer()
  private weak var configuredPlayer: AVPlayer?
  private var configuredScalingMode: VideoScalingMode?
  private var configuredColor: ColorSettings?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.black.cgColor
    playerLayer.videoGravity = .resizeAspect
    layer?.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    playerLayer.frame = bounds
  }

  func update(
    player: AVPlayer,
    scalingMode: VideoScalingMode,
    color: ColorSettings
  ) {
    if configuredPlayer !== player {
      configuredPlayer = player
      playerLayer.player = player
    }
    if configuredScalingMode != scalingMode {
      configuredScalingMode = scalingMode
      playerLayer.videoGravity =
        scalingMode == .fill ? .resizeAspectFill : .resizeAspect
    }
    if configuredColor != color {
      configuredColor = color
      playerLayer.filters = ColorPipeline.filters(for: color)
    }
  }
}
