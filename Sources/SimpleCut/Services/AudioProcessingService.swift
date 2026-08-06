@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

struct ProcessedAudio {
  let url: URL
}

enum AudioProcessingService {
  private static let maximumFrames: AVAudioFrameCount = 4_096

  static func process(
    clips: [VideoClip],
    settings: AudioSettings
  ) async throws -> ProcessedAudio? {
    guard try await clipsContainAudio(clips) else { return nil }
    let source = try await AudioRenderService.render(clips: clips)
    defer { try? FileManager.default.removeItem(at: source) }

    let pcmDestination = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCut-Processed-\(UUID().uuidString).caf")
    try renderAutoEnhancedAudio(
      from: source,
      to: pcmDestination,
      settings: settings
    )
    defer { try? FileManager.default.removeItem(at: pcmDestination) }

    return ProcessedAudio(url: try await encodeM4A(from: pcmDestination))
  }

  private static func renderAutoEnhancedAudio(
    from source: URL,
    to destination: URL,
    settings: AudioSettings
  ) throws {
    let inputFile = try AVAudioFile(forReading: source)
    let format = inputFile.processingFormat
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let dynamics = makeEffect(subtype: kAudioUnitSubType_DynamicsProcessor)
    let limiter = makeEffect(subtype: kAudioUnitSubType_PeakLimiter)

    engine.attach(player)
    engine.attach(dynamics)
    engine.attach(limiter)
    engine.connect(player, to: dynamics, format: format)
    engine.connect(dynamics, to: limiter, format: format)
    engine.connect(limiter, to: engine.mainMixerNode, format: format)

    dynamics.bypass = !settings.normalizeLoudness
    limiter.bypass = !settings.limiterEnabled
    try applyAutoPreset(to: dynamics, settings: settings)
    try setParameter(
      kLimiterParam_PreGain,
      value: 0,
      on: limiter
    )
    engine.mainMixerNode.outputVolume = settings.limiterEnabled
      ? Float(pow(10, settings.peakCeilingDB / 20))
      : 1

    try engine.enableManualRenderingMode(
      .offline,
      format: format,
      maximumFrameCount: maximumFrames
    )
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: engine.manualRenderingFormat,
      frameCapacity: maximumFrames
    ) else {
      throw EditorError.exportFailed
    }
    let outputFile = try AVAudioFile(
      forWriting: destination,
      settings: engine.manualRenderingFormat.settings
    )

    player.scheduleFile(inputFile, at: nil)
    engine.prepare()
    try engine.start()
    player.play()
    defer {
      player.stop()
      engine.stop()
    }

    var emptyRenderCount = 0
    while engine.manualRenderingSampleTime < inputFile.length {
      let remaining = inputFile.length - engine.manualRenderingSampleTime
      let frames = min(maximumFrames, AVAudioFrameCount(remaining))
      switch try engine.renderOffline(frames, to: buffer) {
      case .success:
        emptyRenderCount = 0
        try outputFile.write(from: buffer)
      case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
        emptyRenderCount += 1
        guard emptyRenderCount < 100 else {
          throw EditorError.exportFailed
        }
      case .error:
        throw EditorError.exportFailed
      @unknown default:
        throw EditorError.exportFailed
      }
    }
  }

  private static func applyAutoPreset(
    to dynamics: AVAudioUnitEffect,
    settings: AudioSettings
  ) throws {
    guard settings.normalizeLoudness else { return }

    // A restrained one-click preset: quiet material gets makeup gain while
    // Apple’s Dynamics Processor compresses louder passages automatically.
    try setParameter(
      kDynamicsProcessorParam_Threshold,
      value: -20,
      on: dynamics
    )
    try setParameter(
      kDynamicsProcessorParam_HeadRoom,
      value: 6,
      on: dynamics
    )
    try setParameter(
      kDynamicsProcessorParam_ExpansionRatio,
      value: 1,
      on: dynamics
    )
    try setParameter(
      kDynamicsProcessorParam_AttackTime,
      value: 0.005,
      on: dynamics
    )
    try setParameter(
      kDynamicsProcessorParam_ReleaseTime,
      value: 0.12,
      on: dynamics
    )
    try setParameter(
      kDynamicsProcessorParam_OverallGain,
      value: 8,
      on: dynamics
    )
  }

  private static func makeEffect(subtype: OSType) -> AVAudioUnitEffect {
    AVAudioUnitEffect(
      audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: subtype,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
      )
    )
  }

  private static func setParameter(
    _ parameter: AudioUnitParameterID,
    value: AudioUnitParameterValue,
    on effect: AVAudioUnitEffect
  ) throws {
    guard
      let parameter = effect.auAudioUnit.parameterTree?.parameter(
        withAddress: AUParameterAddress(parameter)
      )
    else {
      throw EditorError.exportFailed
    }
    parameter.value = value
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
}
