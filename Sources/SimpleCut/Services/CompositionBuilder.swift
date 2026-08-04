@preconcurrency import AVFoundation
import CoreGraphics

struct BuiltComposition {
  let asset: AVMutableComposition
  let videoComposition: AVMutableVideoComposition
}

enum CompositionBuilder {
  static func build(
    clips: [VideoClip],
    canvas: CanvasPreset,
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
    let compositionAudio = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    )

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = canvas.size
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    var instructions: [AVVideoCompositionInstructionProtocol] = []
    var insertionTime = CMTime.zero

    for clip in clips {
      let asset = AVURLAsset(url: clip.sourceURL)
      guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
        continue
      }
      let sourceRange = CMTimeRange(
        start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
        duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
      )
      try compositionVideo.insertTimeRange(
        sourceRange,
        of: videoTrack,
        at: insertionTime
      )

      if replacementAudioURL == nil,
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
      {
        try? compositionAudio?.insertTimeRange(
          sourceRange,
          of: audioTrack,
          at: insertionTime
        )
      }

      let naturalSize = try await videoTrack.load(.naturalSize)
      let preferredTransform = try await videoTrack.load(.preferredTransform)
      let displayRect = CGRect(origin: .zero, size: naturalSize)
        .applying(preferredTransform)
        .standardized
      let orientedSize = displayRect.size
      let scale = min(
        canvas.size.width / max(orientedSize.width, 1),
        canvas.size.height / max(orientedSize.height, 1)
      )
      let fittedSize = CGSize(
        width: orientedSize.width * scale,
        height: orientedSize.height * scale
      )
      let offset = CGPoint(
        x: (canvas.size.width - fittedSize.width) / 2,
        y: (canvas.size.height - fittedSize.height) / 2
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
      try compositionAudio?.insertTimeRange(
        CMTimeRange(
          start: .zero,
          duration: replacementDuration
        ),
        of: replacementTrack,
        at: .zero
      )
    }

    videoComposition.instructions = instructions
    return BuiltComposition(
      asset: composition,
      videoComposition: videoComposition
    )
  }
}
