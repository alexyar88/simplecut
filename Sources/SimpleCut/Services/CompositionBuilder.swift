@preconcurrency import AVFoundation
import CoreGraphics

struct BuiltComposition {
  let asset: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
  let audioMix: AVAudioMix?
}

enum CompositionBuilder {
  static func build(
    clips: [VideoClip],
    canvas: CanvasPreset,
    scalingMode: VideoScalingMode = .fit,
    outputSize: CGSize? = nil,
    replacementAudioURL: URL? = nil
  ) async throws -> BuiltComposition {
    let composition = AVMutableComposition()
    guard
      let compositionVideo = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw EditorError.missingVideoTrack
    }
    let videoComposition = AVMutableVideoComposition()
    let renderSize = outputSize ?? canvas.size
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    var instructions: [AVVideoCompositionInstructionProtocol] = []
    var insertionTime = CMTime.zero

    for clip in clips {
      let asset = AVURLAsset(url: clip.sourceURL)
      guard
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
      else {
        throw EditorError.missingVideoTrack
      }
      let assetDuration = try await asset.load(.duration)
      let sourceStart = CMTime(
        seconds: clip.sourceStart,
        preferredTimescale: 600
      )
      let requestedEnd = CMTime(
        seconds: clip.sourceEnd,
        preferredTimescale: 600
      )
      let sourceEnd = CMTimeMinimum(requestedEnd, assetDuration)
      let sourceRange = CMTimeRange(
        start: sourceStart,
        end: sourceEnd
      )
      guard sourceRange.duration > .zero else { continue }
      try compositionVideo.insertTimeRange(
        sourceRange,
        of: videoTrack,
        at: insertionTime
      )

      let naturalSize = try await videoTrack.load(.naturalSize)
      let preferredTransform = try await videoTrack.load(.preferredTransform)
      let displayRect = CGRect(origin: .zero, size: naturalSize)
        .applying(preferredTransform)
        .standardized
      let orientedSize = displayRect.size
      let horizontalScale = renderSize.width / max(orientedSize.width, 1)
      let verticalScale = renderSize.height / max(orientedSize.height, 1)
      let scale =
        scalingMode == .fill
        ? max(horizontalScale, verticalScale)
        : min(horizontalScale, verticalScale)
      let fittedSize = CGSize(
        width: orientedSize.width * scale,
        height: orientedSize.height * scale
      )
      let offset = CGPoint(
        x: (renderSize.width - fittedSize.width) / 2,
        y: (renderSize.height - fittedSize.height) / 2
      )
      var transform = preferredTransform
      transform = transform.concatenating(
        CGAffineTransform(
          translationX: -displayRect.minX,
          y: -displayRect.minY
        )
      )
      transform = transform.concatenating(
        CGAffineTransform(scaleX: scale, y: scale)
      )
      transform = transform.concatenating(
        CGAffineTransform(translationX: offset.x, y: offset.y)
      )

      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(
        start: insertionTime,
        duration: sourceRange.duration
      )
      let layer = AVMutableVideoCompositionLayerInstruction(
        assetTrack: compositionVideo
      )
      layer.setTransform(transform, at: insertionTime)
      instruction.layerInstructions = [layer]
      instructions.append(instruction)
      insertionTime = insertionTime + sourceRange.duration
    }

    let audioMix: AVAudioMix?
    if let replacementAudioURL {
      let replacementAsset = AVURLAsset(url: replacementAudioURL)
      guard
        let replacementTrack = try await replacementAsset
          .loadTracks(withMediaType: .audio).first
      else {
        throw EditorError.exportFailed
      }
      let replacementDuration = CMTimeMinimum(
        insertionTime,
        try await replacementAsset.load(.duration)
      )
      guard
        let compositionAudio = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        throw EditorError.exportFailed
      }
      try compositionAudio.insertTimeRange(
        CMTimeRange(
          start: .zero,
          duration: replacementDuration
        ),
        of: replacementTrack,
        at: .zero
      )
      audioMix = nil
    } else {
      audioMix = try await AudioRenderService.insertAudio(
        clips: clips,
        into: composition
      )
    }

    videoComposition.instructions = instructions
    return BuiltComposition(
      asset: composition,
      videoComposition: videoComposition,
      audioMix: audioMix
    )
  }
}
