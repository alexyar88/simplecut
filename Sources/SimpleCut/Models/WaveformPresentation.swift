import Foundation

struct WaveformPresentationSample: Equatable {
  let level: Float
  let reachesLimiter: Bool
  let clipsWithoutLimiter: Bool
}

enum WaveformPresentation {
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
    let manualGain = Float(pow(10, settings.masterGainDB / 20))
    guard settings.normalizeLoudness else { return manualGain }

    // Bucket peaks are intentionally used here instead of pretending they are
    // LUFS measurements. Bringing a representative peak close to the limiter
    // makes the preview communicate the same gain/limiting decision as export.
    let levels = waveform.map { abs($0) }.filter { $0 > 0.001 }.sorted()
    guard !levels.isEmpty else { return manualGain }
    let percentileIndex = min(
      levels.count - 1,
      Int(Double(levels.count - 1) * 0.78)
    )
    let representativePeak = max(levels[percentileIndex], 0.02)
    let ceiling = Float(pow(10, settings.peakCeilingDB / 20))
    let target = ceiling * 0.82
    let automaticGain = min(Float(pow(10, 12.0 / 20)), target / representativePeak)
    return manualGain * max(1, automaticGain)
  }
}
