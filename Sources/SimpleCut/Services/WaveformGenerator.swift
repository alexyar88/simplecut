@preconcurrency import AVFoundation
import Foundation

private actor WaveformSourceCache {
  struct Key: Hashable, Sendable {
    let url: URL
    let modificationTime: TimeInterval
    let samplesPerSecond: Int
  }

  private var values: [Key: [Float]] = [:]
  private var order: [Key] = []
  private let limit = 12

  func value(for key: Key) -> [Float]? {
    guard let value = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return value
  }

  func store(_ value: [Float], for key: Key) {
    values[key] = value
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > limit {
      values.removeValue(forKey: order.removeFirst())
    }
  }
}

enum WaveformGenerator {
  private static let cache = WaveformSourceCache()
  private static let resolutionTiers = [24, 48, 96, 192, 240]

  static func samples(
    from clips: [VideoClip],
    targetSampleCount: Int
  ) async throws -> [Float] {
    guard !clips.isEmpty else { return [] }
    let work = Task.detached(priority: .utility) {
      let totalDuration = max(
        clips.reduce(0) { $0 + $1.duration },
        0.001
      )
      let requestedDensity = Int(
        ceil(Double(max(1, targetSampleCount)) / totalDuration)
      )
      let samplesPerSecond = resolutionTiers.first {
        $0 >= requestedDensity
      } ?? resolutionTiers.last!
      var sources: [URL: [Float]] = [:]

      for url in Set(clips.map(\.sourceURL)) {
        try Task.checkCancellation()
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: url.path
        )
        let modificationTime = (attributes?[.modificationDate] as? Date)?
          .timeIntervalSinceReferenceDate ?? 0
        let key = WaveformSourceCache.Key(
          url: url,
          modificationTime: modificationTime,
          samplesPerSecond: samplesPerSecond
        )
        if let cached = await cache.value(for: key) {
          sources[url] = cached
          continue
        }
        let generated = try await sourceSamples(
          from: url,
          samplesPerSecond: samplesPerSecond
        )
        try Task.checkCancellation()
        await cache.store(generated, for: key)
        sources[url] = generated
      }

      var result: [Float] = []
      result.reserveCapacity(Int(ceil(totalDuration * Double(samplesPerSecond))))
      for clip in clips {
        try Task.checkCancellation()
        let source = sources[clip.sourceURL] ?? []
        let start = max(0, Int(floor(clip.sourceStart * Double(samplesPerSecond))))
        let count = max(1, Int(ceil(clip.duration * Double(samplesPerSecond))))
        for offset in 0..<count {
          let index = start + offset
          result.append(source.indices.contains(index) ? source[index] : 0)
        }
      }
      return WaveformPresentation.peakResampled(
        result,
        targetSampleCount: max(1, targetSampleCount)
      )
    }
    return try await withTaskCancellationHandler {
      try await work.value
    } onCancel: {
      work.cancel()
    }
  }

  private static func sourceSamples(
    from url: URL,
    samplesPerSecond: Int
  ) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard
      let track = try await asset.loadTracks(withMediaType: .audio).first
    else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let requestedSampleRate = 44_100
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: requestedSampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    reader.startReading()

    let assetDuration = try await asset.load(.duration).seconds
    var result = [Float](
      repeating: 0,
      count: max(1, Int(ceil(assetDuration * Double(samplesPerSecond))))
    )
    var fallbackPresentationTime = 0.0
    while let sampleBuffer = output.copyNextSampleBuffer(),
      let block = CMSampleBufferGetDataBuffer(sampleBuffer)
    {
      try Task.checkCancellation()
      var length = 0
      var pointer: UnsafeMutablePointer<Int8>?
      let status = CMBlockBufferGetDataPointer(
        block,
        atOffset: 0,
        lengthAtOffsetOut: nil,
        totalLengthOut: &length,
        dataPointerOut: &pointer
      )
      guard status == kCMBlockBufferNoErr, let pointer else { continue }
      let sampleCount = length / MemoryLayout<Int16>.size
      let frameCount = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
      let channels = max(1, sampleCount / frameCount)
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
      let actualSampleRate = formatDescription
        .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?
        .pointee.mSampleRate ?? Double(requestedSampleRate)
      let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
      let presentationTime = timestamp.isFinite
        ? timestamp
        : fallbackPresentationTime
      pointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { values in
        for frame in 0..<frameCount {
          var framePeak: Float = 0
          for channel in 0..<channels {
            let index = frame * channels + channel
            guard index < sampleCount else { break }
            framePeak = max(
              framePeak,
              min(1, abs(Float(values[index]) / Float(Int16.max)))
            )
          }
          let frameTime = presentationTime + Double(frame) / actualSampleRate
          let bucket = Int(floor(frameTime * Double(samplesPerSecond)))
          guard bucket >= 0 else { continue }
          if bucket >= result.count {
            result.append(
              contentsOf: repeatElement(0, count: bucket - result.count + 1)
            )
          }
          result[bucket] = max(result[bucket], framePeak)
        }
      }
      fallbackPresentationTime = presentationTime
        + Double(frameCount) / actualSampleRate
    }
    return result
  }
}
