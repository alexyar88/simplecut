import Foundation

struct WaveformPresentationSample: Equatable {
  let level: Float
  let reachesLimiter: Bool
  let clipsWithoutLimiter: Bool
}

enum WaveformPresentation {
  static func remapped(
    _ waveform: [Float],
    from oldClips: [VideoClip],
    to newClips: [VideoClip]
  ) -> [Float] {
    guard !waveform.isEmpty, !oldClips.isEmpty, !newClips.isEmpty else {
      return newClips.isEmpty ? [] : waveform
    }
    let oldDuration = oldClips.reduce(0) { $0 + $1.duration }
    let newDuration = newClips.reduce(0) { $0 + $1.duration }
    guard oldDuration > 0, newDuration > 0 else { return [] }

    struct Segment {
      let clip: VideoClip
      let timelineStart: Double
    }
    var elapsed = 0.0
    var oldSegmentsByURL: [URL: [Segment]] = [:]
    for clip in oldClips {
      let segment = Segment(clip: clip, timelineStart: elapsed)
      oldSegmentsByURL[clip.sourceURL.standardizedFileURL, default: []]
        .append(segment)
      elapsed += clip.duration
    }
    for url in oldSegmentsByURL.keys {
      oldSegmentsByURL[url]?.sort {
        $0.clip.sourceStart < $1.clip.sourceStart
      }
    }

    let targetCount = max(
      1,
      Int((Double(waveform.count) * newDuration / oldDuration).rounded())
    )
    var result = [Float](repeating: 0, count: targetCount)
    elapsed = 0
    var outputIndex = 0
    for newClip in newClips {
      let candidates = oldSegmentsByURL[
        newClip.sourceURL.standardizedFileURL
      ] ?? []
      var candidateIndex = candidates.firstIndex(where: {
        $0.clip.sourceEnd >= newClip.sourceStart - 0.0001
      }) ?? candidates.count
      let clipEnd = elapsed + newClip.duration
      while outputIndex < targetCount {
        let newTime = (Double(outputIndex) + 0.5)
          / Double(targetCount) * newDuration
        guard newTime < clipEnd || outputIndex == targetCount - 1 else {
          break
        }
        let sourceTime = newClip.sourceStart + max(0, newTime - elapsed)
        while candidateIndex < candidates.count - 1,
          sourceTime > candidates[candidateIndex].clip.sourceEnd + 0.0001
        {
          candidateIndex += 1
        }
        if candidateIndex < candidates.count {
          let old = candidates[candidateIndex]
          guard sourceTime >= old.clip.sourceStart - 0.0001,
            sourceTime <= old.clip.sourceEnd + 0.0001
          else {
            outputIndex += 1
            continue
          }
          let oldTime = old.timelineStart + sourceTime - old.clip.sourceStart
          let oldIndex = min(
            waveform.count - 1,
            max(0, Int(oldTime / oldDuration * Double(waveform.count)))
          )
          result[outputIndex] = waveform[oldIndex]
        }
        outputIndex += 1
      }
      elapsed = clipEnd
    }
    return result
  }

  static func displaySamples(
    from waveform: [Float],
    settings: AudioSettings,
    targetSampleCount: Int
  ) -> [WaveformPresentationSample] {
    samples(
      from: peakResampled(waveform, targetSampleCount: targetSampleCount),
      settings: settings
    )
  }

  static func peakResampled(
    _ waveform: [Float],
    targetSampleCount: Int
  ) -> [Float] {
    guard !waveform.isEmpty, targetSampleCount > 0 else { return [] }
    guard waveform.count > targetSampleCount else { return waveform }
    let bucketSize = Double(waveform.count) / Double(targetSampleCount)
    return (0..<targetSampleCount).map { bucket in
      let lower = Int(Double(bucket) * bucketSize)
      let upper = min(
        waveform.count,
        max(lower + 1, Int(ceil(Double(bucket + 1) * bucketSize)))
      )
      return waveform[lower..<upper].max(by: { abs($0) < abs($1) }) ?? 0
    }
  }

  static func samples(
    from waveform: [Float],
    settings: AudioSettings
  ) -> [WaveformPresentationSample] {
    guard !waveform.isEmpty else { return [] }

    let ceiling = Float(pow(10, settings.peakCeilingDB / 20))
    let gain = displayGain(for: waveform, settings: settings)

    return waveform.map { sample in
      let boosted = abs(sample) * gain
      let rendered = settings.normalizeLoudness && settings.limiterEnabled
        ? min(boosted, ceiling)
        : min(boosted, 1)
      return WaveformPresentationSample(
        level: min(1, max(0, rendered)),
        reachesLimiter: settings.normalizeLoudness
          && settings.limiterEnabled
          && boosted >= ceiling,
        clipsWithoutLimiter: settings.normalizeLoudness && boosted >= 1
      )
    }
  }

  private static func displayGain(
    for waveform: [Float],
    settings: AudioSettings
  ) -> Float {
    guard settings.normalizeLoudness else { return 1 }

    // Bucket peaks are intentionally used here instead of pretending they are
    // LUFS measurements. Bringing a representative peak close to the limiter
    // makes the preview communicate the same gain/limiting decision as export.
    let levels = waveform.map { abs($0) }.filter { $0 > 0.001 }.sorted()
    guard !levels.isEmpty else { return 1 }
    let percentileIndex = min(
      levels.count - 1,
      Int(Double(levels.count - 1) * 0.78)
    )
    let representativePeak = max(levels[percentileIndex], 0.02)
    let ceiling = Float(pow(10, settings.peakCeilingDB / 20))
    let target = ceiling * 0.82
    let automaticGain = min(Float(pow(10, 12.0 / 20)), target / representativePeak)
    return max(1, automaticGain)
  }
}
