@preconcurrency import AVFoundation
import Foundation

enum AudioRenderService {
  static let edgeFadeDuration = 0.005
  static let crossfadeDuration = 0.010

  private struct ClipAudio {
    let clip: VideoClip
    // AVAssetTrack does not keep its parent asset alive strongly enough for a
    // later composition insertion on every macOS version.
    let sourceAsset: AVURLAsset
    let sourceTrack: AVAssetTrack?
    let sourceTimeRange: CMTimeRange
    let timelineStart: CMTime
  }

  static func render(clips: [VideoClip]) async throws -> URL {
    let composition = AVMutableComposition()
    let audioMix = try await insertAudio(clips: clips, into: composition)

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCut-Transcript-\(UUID().uuidString).m4a")
    guard
      let session = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetAppleM4A
      )
    else {
      throw EditorError.exportFailed
    }
    session.audioMix = audioMix
    session.outputURL = destination
    session.outputFileType = .m4a
    await session.export()
    guard session.status == .completed else {
      throw session.error ?? EditorError.exportFailed
    }
    return destination
  }

  /// Inserts the clip audio without changing the video timeline. At a cut, the
  /// adjacent sources use 5 ms handles on each side, producing a 10 ms
  /// crossfade centered on the edit. If either handle is unavailable, the two
  /// sides receive independent 5 ms edge fades instead.
  static func insertAudio(
    clips: [VideoClip],
    into composition: AVMutableComposition
  ) async throws -> AVAudioMix? {
    var clipAudio: [ClipAudio] = []
    var timelineStart = CMTime.zero

    for clip in clips {
      let asset = AVURLAsset(url: clip.sourceURL)
      let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first
      let sourceTimeRange = try await sourceTrack?.load(.timeRange) ?? .invalid
      clipAudio.append(
        ClipAudio(
          clip: clip,
          sourceAsset: asset,
          sourceTrack: sourceTrack,
          sourceTimeRange: sourceTimeRange,
          timelineStart: timelineStart
        )
      )
      timelineStart = timelineStart + time(clip.duration)
    }

    guard clipAudio.contains(where: { $0.sourceTrack != nil }) else {
      return nil
    }
    let usedSlots = Set(
      clipAudio.indices.compactMap { index in
        clipAudio[index].sourceTrack == nil ? nil : index % 2
      }
    )
    var tracks: [Int: AVMutableCompositionTrack] = [:]
    var parameters: [Int: AVMutableAudioMixInputParameters] = [:]
    for slot in usedSlots.sorted() {
      guard
        let track = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        throw EditorError.invalidMedia
      }
      tracks[slot] = track
      parameters[slot] = AVMutableAudioMixInputParameters(track: track)
    }
    let halfCrossfade = crossfadeDuration / 2
    let crossfadeBoundaries = max(0, clipAudio.count - 1)
    var usesCrossfade = [Bool](repeating: false, count: crossfadeBoundaries)

    for boundary in usesCrossfade.indices {
      let left = clipAudio[boundary]
      let right = clipAudio[boundary + 1]
      guard left.sourceTrack != nil, right.sourceTrack != nil else { continue }
      let leftHandle = left.sourceTimeRange.end.seconds - left.clip.sourceEnd
      let rightHandle = right.clip.sourceStart - right.sourceTimeRange.start.seconds
      usesCrossfade[boundary] =
        leftHandle >= halfCrossfade - 0.000_001
        && rightHandle >= halfCrossfade - 0.000_001
    }

    for index in clipAudio.indices {
      let item = clipAudio[index]
      guard let sourceTrack = item.sourceTrack else { continue }
      let hasIncomingCrossfade = index > 0 && usesCrossfade[index - 1]
      let hasOutgoingCrossfade =
        index < usesCrossfade.count && usesCrossfade[index]
      let sourceStart = item.clip.sourceStart
        - (hasIncomingCrossfade ? halfCrossfade : 0)
      let sourceDuration = item.clip.duration
        + (hasIncomingCrossfade ? halfCrossfade : 0)
        + (hasOutgoingCrossfade ? halfCrossfade : 0)
      let insertionTime = item.timelineStart
        - time(hasIncomingCrossfade ? halfCrossfade : 0)
      let slot = index % 2
      guard
        let destinationTrack = tracks[slot],
        let input = parameters[slot]
      else {
        throw EditorError.invalidMedia
      }

      try destinationTrack.insertTimeRange(
        CMTimeRange(
          start: time(sourceStart),
          duration: time(sourceDuration)
        ),
        of: sourceTrack,
        at: insertionTime
      )

      let nominalStart = item.timelineStart
      let nominalEnd = item.timelineStart + time(item.clip.duration)
      if hasIncomingCrossfade {
        input.setVolumeRamp(
          fromStartVolume: 0,
          toEndVolume: 1,
          timeRange: CMTimeRange(
            start: nominalStart - time(halfCrossfade),
            duration: time(crossfadeDuration)
          )
        )
      } else {
        let duration = min(edgeFadeDuration, item.clip.duration / 2)
        input.setVolumeRamp(
          fromStartVolume: 0,
          toEndVolume: 1,
          timeRange: CMTimeRange(
            start: nominalStart,
            duration: time(duration)
          )
        )
      }

      if hasOutgoingCrossfade {
        input.setVolumeRamp(
          fromStartVolume: 1,
          toEndVolume: 0,
          timeRange: CMTimeRange(
            start: nominalEnd - time(halfCrossfade),
            duration: time(crossfadeDuration)
          )
        )
      } else {
        let duration = min(edgeFadeDuration, item.clip.duration / 2)
        input.setVolumeRamp(
          fromStartVolume: 1,
          toEndVolume: 0,
          timeRange: CMTimeRange(
            start: nominalEnd - time(duration),
            duration: time(duration)
          )
        )
      }
    }

    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters.keys.sorted().compactMap { parameters[$0] }
    return mix
  }

  private static func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
  }
}
