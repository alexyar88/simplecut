@preconcurrency import AVFoundation
import CoreVideo
import XCTest

@testable import SimpleCut

final class MediaPipelineTests: XCTestCase {
  func testRecordedVideoIsAddedWithoutSecondCopy() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCutRecording-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = directory.appendingPathComponent("recording.mov")
    try await makeTestMovie(at: recording, duration: 1)
    let result = await withCheckedContinuation { continuation in
      Task { @MainActor in
        let project = EditorProject(loadRecovery: false)
        project.importVideo(
          recording,
          copyToLibrary: false
        ) { succeeded in
          continuation.resume(
            returning: (
              succeeded,
              project.isBusy,
              project.clips,
              project.status
            )
          )
        }
      }
    }

    XCTAssertTrue(result.0)
    XCTAssertFalse(result.1)
    XCTAssertEqual(result.2.count, 1)
    XCTAssertEqual(result.2[0].sourceURL, recording)
    XCTAssertEqual(result.3, "Видео импортировано")
  }

  func testWaveformSplitAndOverlayExport() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCutTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appendingPathComponent("source.mov")
    try await makeTestMovie(at: source, duration: 2)

    let sourceAsset = AVURLAsset(url: source)
    let duration = try await sourceAsset.load(.duration).seconds
    XCTAssertEqual(duration, 2, accuracy: 0.08)

    let fullClip = VideoClip(
      sourceURL: source,
      sourceStart: 0,
      duration: duration
    )
    let waveform = try await WaveformGenerator.samples(
      from: [fullClip],
      targetSampleCount: 100
    )
    XCTAssertGreaterThan(waveform.count, 20)
    XCTAssertGreaterThan(waveform.max() ?? 0, 0.1)

    let clips = [
      VideoClip(sourceURL: source, sourceStart: 0, duration: 0.75),
      VideoClip(sourceURL: source, sourceStart: 1.1, duration: 0.9),
    ]
    let overlay = OverlayItem(
      kind: .text,
      startTime: 0.2,
      duration: 1,
      text: "SimpleCut"
    )
    let output = directory.appendingPathComponent("export.mp4")
    try await ExportService.export(
      clips: clips,
      overlays: [overlay],
      canvas: .horizontal,
      color: .automatic,
      to: output
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    XCTAssertGreaterThan(
      (try FileManager.default.attributesOfItem(atPath: output.path)[.size]
        as? NSNumber)?.intValue ?? 0,
      1_000
    )
    let exportedAsset = AVURLAsset(url: output)
    let exportedDuration = try await exportedAsset.load(.duration).seconds
    let exportedVideoTracks = try await exportedAsset.loadTracks(
      withMediaType: .video
    )
    let exportedAudioTracks = try await exportedAsset.loadTracks(
      withMediaType: .audio
    )
    XCTAssertEqual(exportedDuration, 1.65, accuracy: 0.1)
    XCTAssertEqual(exportedVideoTracks.count, 1)
    XCTAssertEqual(exportedAudioTracks.count, 1)
  }

  func testAudioNormalizationAndPeakLimiter() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCutAudio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mov")
    try await makeTestMovie(at: source, duration: 1)
    let settings = AudioSettings(
      normalizeLoudness: true,
      targetLUFS: -18,
      limiterEnabled: true,
      peakCeilingDB: -6,
      masterGainDB: 0
    )
    let result = try await AudioProcessingService.process(
      clips: [
        VideoClip(sourceURL: source, sourceStart: 0, duration: 1)
      ],
      settings: settings
    )
    let processed = try XCTUnwrap(result)
    defer { try? FileManager.default.removeItem(at: processed.url) }

    XCTAssertTrue(processed.measurement.estimatedLUFS.isFinite)
    XCTAssertLessThanOrEqual(
      processed.appliedGainDB + processed.measurement.peakDBFS,
      settings.peakCeilingDB + 0.01
    )
    let file = try AVAudioFile(forReading: processed.url)
    let format = file.processingFormat
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)
    )
    var peak: Float = 0
    while file.framePosition < file.length {
      try file.read(into: buffer)
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
          peak = max(peak, abs(channels[channel][frame]))
        }
      }
    }
    XCTAssertLessThanOrEqual(
      peak,
      Float(pow(10, settings.peakCeilingDB / 20)) + 0.01
    )
  }

  @MainActor
  func testLocalTranscriptionWhenEnabled() async throws {
    guard
      ProcessInfo.processInfo.environment["SIMPLECUT_RUN_MODEL_TEST"] == "1"
    else {
      throw XCTSkip("Set SIMPLECUT_RUN_MODEL_TEST=1 to download and test Whisper")
    }

    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCut-Speech-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let speech = Process()
    speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    speech.arguments = [
      "-v", "Samantha",
      "Simple Cut creates local subtitles.",
      "-o", audioURL.path,
    ]
    try speech.run()
    speech.waitUntilExit()
    XCTAssertEqual(speech.terminationStatus, 0)

    let asset = AVURLAsset(url: audioURL)
    let duration = try await asset.load(.duration).seconds
    let service = LocalTranscriptionService()
    let captions = try await service.transcribe(
      clips: [
        VideoClip(
          sourceURL: audioURL,
          sourceStart: 0,
          duration: duration
        )
      ],
      model: .base,
      language: .automatic
    ) { _, _ in }

    XCTAssertFalse(captions.isEmpty)
    XCTAssertTrue(
      captions.map(\.text).joined(separator: " ")
        .localizedCaseInsensitiveContains("Simple")
    )
  }

  private func makeTestMovie(at destination: URL, duration: Double) async throws {
    let directory = destination.deletingLastPathComponent()
    let videoURL = directory.appendingPathComponent("video.mov")
    let audioURL = directory.appendingPathComponent("audio.wav")
    try await makeVideo(at: videoURL, duration: duration)
    try makeAudio(at: audioURL, duration: duration)

    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    let composition = AVMutableComposition()
    let range = CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )

    let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
    let videoSource = try XCTUnwrap(
      videoTracks.first
    )
    let videoTrack = try XCTUnwrap(
      composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    )
    try videoTrack.insertTimeRange(range, of: videoSource, at: .zero)

    let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let audioSource = try XCTUnwrap(
      audioTracks.first
    )
    let audioTrack = try XCTUnwrap(
      composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    )
    try audioTrack.insertTimeRange(range, of: audioSource, at: .zero)

    let session = try XCTUnwrap(
      AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetHighestQuality
      )
    )
    session.outputURL = destination
    session.outputFileType = .mov
    await session.export()
    if session.status != .completed {
      throw session.error ?? EditorError.exportFailed
    }
  }

  private func makeVideo(at destination: URL, duration: Double) async throws {
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: 320,
        AVVideoHeightKey: 180,
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320,
        kCVPixelBufferHeightKey as String: 180,
      ]
    )
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? EditorError.exportFailed
    }
    writer.startSession(atSourceTime: .zero)

    let frameCount = Int(duration * 30)
    for frame in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(2))
      }
      let buffer = try XCTUnwrap(makePixelBuffer(frame: frame))
      guard
        adaptor.append(
          buffer,
          withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
        )
      else {
        throw writer.error ?? EditorError.exportFailed
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(
      writer.status,
      .completed,
      writer.error?.localizedDescription ?? "AVAssetWriter failed"
    )
  }

  private func makePixelBuffer(frame: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      320,
      180,
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ] as CFDictionary,
      &buffer
    )
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let byteCount =
      CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    memset(address, Int32((frame * 3) % 180 + 30), byteCount)
    return buffer
  }

  private func makeAudio(at destination: URL, duration: Double) throws {
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    )
    let frameCount = AVAudioFrameCount(duration * format.sampleRate)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
      samples[frame] =
        sin(2 * .pi * 440 * Float(frame) / Float(format.sampleRate)) * 0.35
    }
    let file = try AVAudioFile(
      forWriting: destination,
      settings: format.settings
    )
    try file.write(from: buffer)
  }
}
