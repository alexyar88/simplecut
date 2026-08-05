@preconcurrency import AVFoundation
import SwiftUI

struct PlayerView: NSViewRepresentable {
  let player: AVPlayer
  let scalingMode: VideoScalingMode

  func makeNSView(context: Context) -> PlayerContainerView {
    let view = PlayerContainerView()
    view.playerLayer.player = player
    view.playerLayer.videoGravity =
      scalingMode == .fill ? .resizeAspectFill : .resizeAspect
    return view
  }

  func updateNSView(_ nsView: PlayerContainerView, context: Context) {
    nsView.playerLayer.player = player
    nsView.playerLayer.videoGravity =
      scalingMode == .fill ? .resizeAspectFill : .resizeAspect
  }
}

final class PlayerContainerView: NSView {
  let playerLayer = AVPlayerLayer()

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
}
