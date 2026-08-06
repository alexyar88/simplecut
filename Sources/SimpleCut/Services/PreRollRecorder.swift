@preconcurrency import AVFoundation
import Foundation

final class PreRollRecorder:
  NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  struct Callbacks: Sendable {
    let didUpdateLevel: @Sendable (Float) -> Void
    let didStart: @Sendable () -> Void
    let didUpdateDuration: @Sendable (Double) -> Void
    let didFinish: @Sendable (URL) -> Void
    let didFail: @Sendable (String) -> Void
  }

  let queue = DispatchQueue(
    label: "app.simplecut.pre-roll-recorder",
    qos: .userInteractive
  )

  private struct BufferedSample {
    let buffer: CMSampleBuffer
    let presentationTime: CMTime
    let isSyncVideoFrame: Bool
  }

  private let preRollDuration = CMTime(seconds: 2, preferredTimescale: 600)
  private let callbacks: Callbacks
  private var videoSamples: [BufferedSample] = []
  private var audioSamples: [BufferedSample] = []
  private var latestPresentationTime = CMTime.invalid
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var destination: URL?
  private var pendingDestination: URL?
  private var pendingRequestedStartTime = CMTime.invalid
  private var trimStart = CMTime.zero
  private var recordingBeganAt = CMTime.invalid
  private var lastReportedDuration = 0.0
  private var isStopping = false
  private var shouldDiscard = false

  init(callbacks: Callbacks) {
    self.callbacks = callbacks
    super.init()
  }

  func start(to destination: URL, requestedStartTime: CMTime) {
    queue.async { [weak self] in
      self?.startOnQueue(
        to: destination,
        requestedStartTime: requestedStartTime
      )
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopOnQueue(discard: false)
    }
  }

  func cancel() {
    queue.async { [weak self] in
      self?.stopOnQueue(discard: true)
    }
  }

  func resetBuffer() {
    queue.async { [weak self] in
      guard let self, writer == nil else { return }
      videoSamples.removeAll(keepingCapacity: true)
      audioSamples.removeAll(keepingCapacity: true)
      latestPresentationTime = .invalid
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    let mediaType = CMFormatDescriptionGetMediaType(
      CMSampleBufferGetFormatDescription(sampleBuffer)!
    )
    if mediaType == kCMMediaType_Audio {
      updateAudioLevel(from: sampleBuffer)
    }
    handle(
      sampleBuffer,
      mediaType: mediaType == kCMMediaType_Video ? .video : .audio
    )
  }

  private func handle(
    _ sampleBuffer: CMSampleBuffer,
    mediaType: AVMediaType
  ) {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard presentationTime.isValid else { return }
    if !latestPresentationTime.isValid
      || CMTimeCompare(presentationTime, latestPresentationTime) > 0
    {
      latestPresentationTime = presentationTime
    }

    if let writer, writer.status == .writing, !isStopping {
      appendLive(sampleBuffer, mediaType: mediaType)
      return
    }
    guard writer == nil else { return }

    let sample = BufferedSample(
      buffer: sampleBuffer,
      presentationTime: presentationTime,
      isSyncVideoFrame: mediaType == .video
        ? Self.isSyncVideoFrame(sampleBuffer)
        : false
    )
    if mediaType == .video {
      videoSamples.append(sample)
    } else {
      audioSamples.append(sample)
    }
    prunePreRoll()
    startPendingRecordingIfReady()
  }

  private func startOnQueue(
    to destination: URL,
    requestedStartTime: CMTime
  ) {
    guard writer == nil, pendingDestination == nil else { return }
    guard hasUsablePreRoll else {
      pendingDestination = destination
      pendingRequestedStartTime = requestedStartTime
      queue.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, self.pendingDestination == destination else { return }
        self.pendingDestination = nil
        self.pendingRequestedStartTime = .invalid
        try? FileManager.default.removeItem(at: destination)
        self.callbacks.didFail(
          "Камера или микрофон не начали передавать данные."
        )
      }
      return
    }
    startPreparedRecording(
      to: destination,
      requestedStartTime: requestedStartTime
    )
  }

  private func startPendingRecordingIfReady() {
    guard let destination = pendingDestination,
      hasUsablePreRoll
    else {
      return
    }
    let requestedStartTime = pendingRequestedStartTime
    pendingDestination = nil
    pendingRequestedStartTime = .invalid
    startPreparedRecording(
      to: destination,
      requestedStartTime: requestedStartTime
    )
  }

  private func startPreparedRecording(
    to destination: URL,
    requestedStartTime: CMTime
  ) {
    do {
      guard
        let firstSyncIndex = videoSamples.firstIndex(where: {
          $0.isSyncVideoFrame
        })
      else {
        throw RecorderError.missingVideoKeyframe
      }
      if firstSyncIndex > 0 {
        videoSamples.removeFirst(firstSyncIndex)
      }
      let firstVideoTime = videoSamples[0].presentationTime
      if let firstAudioToKeep = audioSamples.firstIndex(where: {
        CMTimeCompare($0.presentationTime, firstVideoTime) >= 0
      }), firstAudioToKeep > 0 {
        audioSamples.removeFirst(firstAudioToKeep)
      }

      let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
      guard
        let firstVideoFormat = CMSampleBufferGetFormatDescription(
          videoSamples[0].buffer
        )
      else {
        throw RecorderError.missingVideoFormat
      }
      let videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: firstVideoFormat
      )
      videoInput.expectsMediaDataInRealTime = true
      guard writer.canAdd(videoInput) else {
        throw RecorderError.cannotAddVideoInput
      }
      writer.add(videoInput)

      var audioInput: AVAssetWriterInput?
      if let firstAudio = audioSamples.first,
        let audioFormat = CMSampleBufferGetFormatDescription(firstAudio.buffer)
      {
        guard
          let audioDescription =
            CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?
            .pointee
        else {
          throw RecorderError.missingAudioFormat
        }
        let input = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioDescription.mSampleRate,
            AVNumberOfChannelsKey: Int(
              audioDescription.mChannelsPerFrame
            ),
            AVEncoderBitRateKey: 192_000,
          ],
          sourceFormatHint: audioFormat
        )
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
          writer.add(input)
          audioInput = input
        }
      }

      let sessionStart = videoSamples[0].presentationTime
      guard writer.startWriting() else {
        throw writer.error ?? RecorderError.cannotStartWriter
      }
      writer.startSession(atSourceTime: sessionStart)

      self.writer = writer
      self.videoInput = videoInput
      self.audioInput = audioInput
      self.destination = destination
      let effectiveStart = requestedStartTime.isValid
        ? requestedStartTime
        : latestPresentationTime
      trimStart = CMTimeMaximum(
        .zero,
        CMTimeSubtract(effectiveStart, sessionStart)
      )
      recordingBeganAt = effectiveStart
      lastReportedDuration = 0
      isStopping = false
      shouldDiscard = false

      let bufferedVideo = videoSamples
      let bufferedAudio = audioSamples.filter {
        CMTimeCompare($0.presentationTime, sessionStart) >= 0
      }
      videoSamples.removeAll(keepingCapacity: true)
      audioSamples.removeAll(keepingCapacity: true)

      for sample in bufferedVideo {
        guard videoInput.isReadyForMoreMediaData,
          videoInput.append(sample.buffer)
        else {
          throw writer.error ?? RecorderError.cannotAppendPreRoll
        }
      }
      if let audioInput {
        for sample in bufferedAudio {
          guard audioInput.isReadyForMoreMediaData,
            audioInput.append(sample.buffer)
          else {
            throw writer.error ?? RecorderError.cannotAppendPreRoll
          }
        }
      }
      callbacks.didStart()
    } catch {
      writer?.cancelWriting()
      clearWriter()
      try? FileManager.default.removeItem(at: destination)
      callbacks.didFail(error.localizedDescription)
    }
  }

  private func appendLive(
    _ sampleBuffer: CMSampleBuffer,
    mediaType: AVMediaType
  ) {
    let input = mediaType == .video ? videoInput : audioInput
    guard let input, input.isReadyForMoreMediaData else { return }
    guard input.append(sampleBuffer) else {
      failActiveWriter()
      return
    }
    guard mediaType == .video, recordingBeganAt.isValid else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let duration = max(
      0,
      CMTimeGetSeconds(CMTimeSubtract(timestamp, recordingBeganAt))
    )
    if duration - lastReportedDuration >= 0.03 {
      lastReportedDuration = duration
      callbacks.didUpdateDuration(duration)
    }
  }

  private func stopOnQueue(discard: Bool) {
    if let pendingDestination {
      self.pendingDestination = nil
      pendingRequestedStartTime = .invalid
      if discard {
        try? FileManager.default.removeItem(at: pendingDestination)
      }
      return
    }
    guard let writer, writer.status == .writing, !isStopping else {
      if discard, let destination {
        try? FileManager.default.removeItem(at: destination)
      }
      return
    }
    isStopping = true
    shouldDiscard = discard
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    let finishedDestination = destination
    let finishedTrimStart = trimStart
    writer.finishWriting { [weak self] in
      guard let self else { return }
      self.queue.async {
        let error = self.writer?.error
        let discard = self.shouldDiscard
        self.clearWriter()
        guard let finishedDestination else { return }
        if discard {
          try? FileManager.default.removeItem(at: finishedDestination)
        } else if let error {
          try? FileManager.default.removeItem(at: finishedDestination)
          self.callbacks.didFail(error.localizedDescription)
        } else {
          Task {
            do {
              try await Self.removePreRoll(
                from: finishedDestination,
                startingAt: finishedTrimStart
              )
              self.callbacks.didFinish(finishedDestination)
            } catch {
              try? FileManager.default.removeItem(at: finishedDestination)
              self.callbacks.didFail(error.localizedDescription)
            }
          }
        }
      }
    }
  }

  private func failActiveWriter() {
    let message =
      writer?.error?.localizedDescription
      ?? RecorderError.cannotAppendLive.localizedDescription
    writer?.cancelWriting()
    if let destination {
      try? FileManager.default.removeItem(at: destination)
    }
    clearWriter()
    callbacks.didFail(message)
  }

  private func clearWriter() {
    writer = nil
    videoInput = nil
    audioInput = nil
    destination = nil
    pendingDestination = nil
    pendingRequestedStartTime = .invalid
    trimStart = .zero
    recordingBeganAt = .invalid
    lastReportedDuration = 0
    isStopping = false
    shouldDiscard = false
  }

  private func prunePreRoll() {
    guard latestPresentationTime.isValid else { return }
    let target = CMTimeSubtract(latestPresentationTime, preRollDuration)

    if let keyframeIndex = videoSamples.lastIndex(where: {
      $0.isSyncVideoFrame
        && CMTimeCompare($0.presentationTime, target) <= 0
    }), keyframeIndex > 0 {
      videoSamples.removeFirst(keyframeIndex)
    }

    guard let firstVideoTime = videoSamples.first?.presentationTime else {
      return
    }
    if let firstAudioToKeep = audioSamples.firstIndex(where: {
      CMTimeCompare($0.presentationTime, firstVideoTime) >= 0
    }), firstAudioToKeep > 0 {
      audioSamples.removeFirst(firstAudioToKeep)
    }
  }

  private var hasUsablePreRoll: Bool {
    !audioSamples.isEmpty
      && videoSamples.contains(where: \.isSyncVideoFrame)
  }

  private func updateAudioLevel(from sampleBuffer: CMSampleBuffer) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      return
    }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    guard length > 1 else { return }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return kCMBlockBufferBadCustomBlockSourceErr
      }
      return CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: length,
        destination: baseAddress
      )
    }
    guard status == kCMBlockBufferNoErr else { return }

    let rms: Float = data.withUnsafeBytes { bytes in
      let samples = bytes.bindMemory(to: Int16.self)
      guard !samples.isEmpty else { return 0 }
      var sum: Double = 0
      for sample in samples {
        let normalized = Double(sample) / Double(Int16.max)
        sum += normalized * normalized
      }
      return Float(sqrt(sum / Double(samples.count)))
    }
    let decibels = rms > 0 ? 20 * log10(rms) : -60
    let normalized = min(1, max(0, (decibels + 52) / 52))
    let gated = normalized < 0.12 ? 0 : normalized
    callbacks.didUpdateLevel((gated * 24).rounded() / 24)
  }

  private static func isSyncVideoFrame(
    _ sampleBuffer: CMSampleBuffer
  ) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[CFString: Any]],
      let first = attachments.first
    else {
      return true
    }
    return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
  }

  static func removePreRoll(
    from source: URL,
    startingAt start: CMTime
  ) async throws {
    guard start.isValid, CMTimeCompare(start, .zero) > 0 else { return }
    let asset = AVURLAsset(url: source)
    let duration = try await asset.load(.duration)
    guard CMTimeCompare(duration, start) > 0 else {
      throw RecorderError.invalidTrimRange
    }
    let trimmed = source.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString)-trimmed.mov")
    defer {
      try? FileManager.default.removeItem(at: trimmed)
    }
    guard
      let export = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetPassthrough
      )
    else {
      throw RecorderError.cannotTrimPreRoll
    }
    export.outputURL = trimmed
    export.outputFileType = .mov
    export.timeRange = CMTimeRange(
      start: start,
      duration: CMTimeSubtract(duration, start)
    )
    await export.export()
    guard export.status == .completed else {
      throw export.error ?? RecorderError.cannotTrimPreRoll
    }
    _ = try FileManager.default.replaceItemAt(
      source,
      withItemAt: trimmed
    )
  }
}

private enum RecorderError: LocalizedError {
  case missingVideoFormat
  case missingVideoKeyframe
  case missingAudioFormat
  case cannotAddVideoInput
  case cannotStartWriter
  case cannotAppendPreRoll
  case cannotAppendLive
  case invalidTrimRange
  case cannotTrimPreRoll

  var errorDescription: String? {
    switch self {
    case .missingVideoFormat:
      "Не удалось определить формат камеры."
    case .missingVideoKeyframe:
      "Камера ещё не подготовила ключевой видеокадр."
    case .missingAudioFormat:
      "Не удалось определить формат микрофона."
    case .cannotAddVideoInput:
      "Не удалось подготовить видеодорожку."
    case .cannotStartWriter:
      "Не удалось запустить запись файла."
    case .cannotAppendPreRoll:
      "Не удалось добавить предварительный буфер в запись."
    case .cannotAppendLive:
      "Не удалось продолжить запись видео."
    case .invalidTrimRange:
      "Не удалось определить границу начала записи."
    case .cannotTrimPreRoll:
      "Не удалось удалить технический буфер из готового клипа."
    }
  }
}
