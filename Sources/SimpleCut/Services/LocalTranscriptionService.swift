import Foundation
@preconcurrency import WhisperKit

@MainActor
final class LocalTranscriptionService {
  private var whisperKit: WhisperKit?
  private var loadedModel: TranscriptionModel?

  func transcribe(
    clips: [VideoClip],
    model: TranscriptionModel,
    language: TranscriptionLanguage,
    onStatus: @escaping @MainActor @Sendable (String, Double?) -> Void
  ) async throws -> [CaptionDraft] {
    try Task.checkCancellation()
    onStatus("Подготавливаем звуковую дорожку…", nil)
    let audioURL = try await AudioRenderService.render(clips: clips)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    if whisperKit == nil || loadedModel != model {
      onStatus("Скачиваем модель \(model.title)…", 0)
      let modelDirectory = try modelsDirectory()
      let modelFolder = try await TranscriptionModelDownloader.download(
        model: model,
        directory: modelDirectory,
        onStatus: onStatus
      )
      try Task.checkCancellation()
      onStatus("Загружаем модель в память…", nil)
      let config = WhisperKitConfig(
        model: model.rawValue,
        modelFolder: modelFolder.path,
        verbose: false,
        prewarm: true,
        load: true,
        download: false
      )
      whisperKit = try await WhisperKit(config)
      loadedModel = model
    }

    try Task.checkCancellation()
    guard let whisperKit else {
      throw EditorError.transcriptionFailed
    }
    onStatus("Распознаём речь на устройстве…", nil)
    let options = DecodingOptions(
      language: language.whisperCode,
      detectLanguage: language == .automatic,
      wordTimestamps: true,
      chunkingStrategy: .vad
    )
    let results: [TranscriptionResult] = try await whisperKit.transcribe(
      audioPath: audioURL.path,
      decodeOptions: options,
      callback: nil
    )
    try Task.checkCancellation()

    let words = results.flatMap(\.segments).flatMap { segment in
      (segment.words ?? []).map {
        CaptionWord(
          text: $0.word.trimmingCharacters(in: .whitespacesAndNewlines),
          startTime: Double($0.start),
          endTime: Double($0.end)
        )
      }
    }
    let fallback = results.flatMap(\.segments).map {
      CaptionDraft(
        text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
        startTime: Double($0.start),
        endTime: Double($0.end)
      )
    }
    return CaptionGenerator.makeDrafts(words: words, fallback: fallback)
  }

  private func modelsDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory =
      root
      .appendingPathComponent("SimpleCut", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

private enum TranscriptionModelDownloader {
  nonisolated static func download(
    model: TranscriptionModel,
    directory: URL,
    onStatus: @escaping @MainActor @Sendable (String, Double?) -> Void
  ) async throws -> URL {
    try await WhisperKit.download(
      variant: model.rawValue,
      downloadBase: directory,
      progressCallback: { progress in
        let fraction = progress.fractionCompleted
        Task { @MainActor in
          onStatus("Скачиваем модель \(model.title)…", fraction)
        }
      }
    )
  }
}
