@preconcurrency import AVFoundation
import Foundation

enum WaveformGenerator {
  static func samples(
    from clips: [VideoClip],
    targetSampleCount: Int
  ) async throws -> [Float] {
    guard !clips.isEmpty else { return [] }
    return try await Task.detached(priority: .utility) {
      let totalDuration = max(
        clips.reduce(0) { $0 + $1.duration },
        0.001
      )
      var result: [Float] = []

      for clip in clips {
        let asset = AVURLAsset(url: clip.sourceURL)
        guard
          let track = try await asset.loadTracks(
            withMediaType: .audio
          ).first
        else {
          continue
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
          start: CMTime(
            seconds: clip.sourceStart,
            preferredTimescale: 600
          ),
          duration: CMTime(
            seconds: clip.duration,
            preferredTimescale: 600
          )
        )
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: settings
        )
        reader.add(output)
        reader.startReading()

        let desired = max(
          8,
          Int(Double(targetSampleCount) * clip.duration / totalDuration)
        )
        let estimatedFrames = max(1, Int(44_100 * clip.duration))
        let bucketFrames = max(1, estimatedFrames / desired)
        var peak: Float = 0
        var framesInBucket = 0

        while let sampleBuffer = output.copyNextSampleBuffer(),
          let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        {
          var length = 0
          var pointer: UnsafeMutablePointer<Int8>?
          let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
          )
          guard status == kCMBlockBufferNoErr, let pointer else {
            continue
          }
          let sampleCount = length / MemoryLayout<Int16>.size
          pointer.withMemoryRebound(
            to: Int16.self,
            capacity: sampleCount
          ) { values in
            for index in 0..<sampleCount {
              let value = min(
                1,
                abs(Float(values[index]) / Float(Int16.max))
              )
              peak = max(peak, value)
              framesInBucket += 1
              if framesInBucket >= bucketFrames {
                result.append(max(0.02, peak))
                peak = 0
                framesInBucket = 0
              }
            }
          }
        }
        if framesInBucket > 0 {
          result.append(max(0.02, peak))
        }
      }

      if result.count > targetSampleCount {
        let stride = Double(result.count) / Double(targetSampleCount)
        return (0..<targetSampleCount).map { index in
          result[min(Int(Double(index) * stride), result.count - 1)]
        }
      }
      return result
    }.value
  }
}
