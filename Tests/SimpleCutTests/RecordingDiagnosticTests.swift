@preconcurrency import AVFoundation
import XCTest

@testable import SimpleCut

final class RecordingDiagnosticTests: XCTestCase {
  func testExternalCameraRecordingWhenProvided() async throws {
    guard
      let path = ProcessInfo.processInfo.environment[
        "SIMPLECUT_CAMERA_RECORDING_PATH"
      ]
    else {
      throw XCTSkip("Set SIMPLECUT_CAMERA_RECORDING_PATH to inspect a camera recording")
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    print(
      "camera recording:",
      "duration=\(duration.seconds)",
      "size=\(size)",
      "transform=\(transform)"
    )
    let isPlayable = try await asset.load(.isPlayable)
    XCTAssertTrue(isPlayable)

    let sourceGenerator = AVAssetImageGenerator(asset: asset)
    sourceGenerator.appliesPreferredTrackTransform = true
    _ = try await sourceGenerator.image(
      at: CMTime(seconds: min(0.5, duration.seconds / 2), preferredTimescale: 600)
    )

    let built = try await CompositionBuilder.build(
      clips: [
        VideoClip(
          sourceURL: URL(fileURLWithPath: path),
          sourceStart: 0,
          duration: duration.seconds
        )
      ],
      canvas: .vertical
    )
    let compositionGenerator = AVAssetImageGenerator(asset: built.asset)
    compositionGenerator.videoComposition = built.videoComposition
    _ = try await compositionGenerator.image(
      at: CMTime(seconds: min(0.5, duration.seconds / 2), preferredTimescale: 600)
    )
  }
}
