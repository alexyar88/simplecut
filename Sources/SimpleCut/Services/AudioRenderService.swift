@preconcurrency import AVFoundation
import Foundation

enum AudioRenderService {
  static func render(clips: [VideoClip]) async throws -> URL {
    let composition = AVMutableComposition()
    guard
      let destinationTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw EditorError.invalidMedia
    }

    var insertionTime = CMTime.zero
    for clip in clips {
      let asset = AVURLAsset(url: clip.sourceURL)
      guard
        let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first
      else {
        insertionTime =
          insertionTime
          + CMTime(seconds: clip.duration, preferredTimescale: 600)
        continue
      }
      let range = CMTimeRange(
        start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
        duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
      )
      try destinationTrack.insertTimeRange(
        range,
        of: sourceTrack,
        at: insertionTime
      )
      insertionTime = insertionTime + range.duration
    }

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
    session.outputURL = destination
    session.outputFileType = .m4a
    await session.export()
    guard session.status == .completed else {
      throw session.error ?? EditorError.exportFailed
    }
    return destination
  }
}
