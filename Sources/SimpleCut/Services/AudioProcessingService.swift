@preconcurrency import AVFoundation
import Foundation

struct AudioMeasurement: Equatable {
  let estimatedLUFS: Double
  let peakDBFS: Double
}

struct ProcessedAudio {
  let url: URL
  let measurement: AudioMeasurement
  let appliedGainDB: Double
}

enum AudioProcessingService {
  static func process(
    clips: [VideoClip],
    settings: AudioSettings
  ) async throws -> ProcessedAudio? {
    guard try await clipsContainAudio(clips) else { return nil }
    let source = try await AudioRenderService.render(clips: clips)
    defer { try? FileManager.default.removeItem(at: source) }

    let inputFile = try AVAudioFile(forReading: source)
    let measurement = try measure(inputFile)
    var gain = settings.masterGainDB
    if settings.normalizeLoudness {
      gain += settings.targetLUFS - measurement.estimatedLUFS
    }
    if settings.limiterEnabled {
      gain = min(gain, settings.peakCeilingDB - measurement.peakDBFS)
    }
    gain = min(12, max(-30, gain))

    let pcmDestination = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCut-Processed-\(UUID().uuidString).caf")
    try render(
      inputFile: inputFile,
      to: pcmDestination,
      gainDB: gain,
      ceilingDB: settings.peakCeilingDB,
      limiterEnabled: settings.limiterEnabled
    )
    defer { try? FileManager.default.removeItem(at: pcmDestination) }
    let destination = try await encodeM4A(from: pcmDestination)
    return ProcessedAudio(
      url: destination,
      measurement: measurement,
      appliedGainDB: gain
    )
  }

  private static func encodeM4A(from source: URL) async throws -> URL {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCut-Processed-\(UUID().uuidString).m4a")
    guard let session = AVAssetExportSession(
      asset: AVURLAsset(url: source),
      presetName: AVAssetExportPresetAppleM4A
    ) else {
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

  private static func clipsContainAudio(_ clips: [VideoClip]) async throws -> Bool {
    for clip in clips {
      let asset = AVURLAsset(url: clip.sourceURL)
      if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
        return true
      }
    }
    return false
  }

  private static func measure(_ file: AVAudioFile) throws -> AudioMeasurement {
    file.framePosition = 0
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: 8_192
    ) else {
      throw EditorError.exportFailed
    }
    var sumSquares = 0.0
    var sampleCount = 0
    var peak = 0.0
    while file.framePosition < file.length {
      try file.read(into: buffer)
      guard let channels = buffer.floatChannelData else {
        throw EditorError.exportFailed
      }
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
          let sample = Double(channels[channel][frame])
          sumSquares += sample * sample
          peak = max(peak, abs(sample))
          sampleCount += 1
        }
      }
    }
    file.framePosition = 0
    guard sampleCount > 0 else {
      return AudioMeasurement(estimatedLUFS: -70, peakDBFS: -70)
    }
    let meanSquare = max(sumSquares / Double(sampleCount), 1e-12)
    let estimatedLUFS = -0.691 + 10 * log10(meanSquare)
    let peakDBFS = 20 * log10(max(peak, 1e-12))
    return AudioMeasurement(
      estimatedLUFS: estimatedLUFS,
      peakDBFS: peakDBFS
    )
  }

  private static func render(
    inputFile: AVAudioFile,
    to destination: URL,
    gainDB: Double,
    ceilingDB: Double,
    limiterEnabled: Bool
  ) throws {
    let format = inputFile.processingFormat
    let output = try AVAudioFile(
      forWriting: destination,
      settings: format.settings
    )
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: 8_192
    ) else {
      throw EditorError.exportFailed
    }
    let gain = Float(pow(10, gainDB / 20))
    let ceiling = Float(pow(10, ceilingDB / 20))
    while inputFile.framePosition < inputFile.length {
      try inputFile.read(into: buffer)
      guard let channels = buffer.floatChannelData else {
        throw EditorError.exportFailed
      }
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
          var sample = channels[channel][frame] * gain
          if limiterEnabled {
            sample = min(ceiling, max(-ceiling, sample))
          }
          channels[channel][frame] = sample
        }
      }
      try output.write(from: buffer)
    }
  }
}
