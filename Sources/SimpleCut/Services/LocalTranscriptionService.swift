import Foundation
@preconcurrency import WhisperKit

@MainActor
final class LocalTranscriptionService {
  private var whisperKit: WhisperKit?
  private var loadedModel: TranscriptionModel?

  func transcribe(
    clips: [VideoClip],
    model: TranscriptionModel,
    onStatus: @escaping @MainActor (String, Double?) -> Void
  ) async throws -> [CaptionDraft] {
    onStatus("Подготавливаем звуковую дорожку…", nil)
    let audioURL = try await AudioRenderService.render(clips: clips)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    if whisperKit == nil || loadedModel != model {
      onStatus("Скачиваем модель \(model.title)…", 0)
      let modelDirectory = try modelsDirectory()
      let modelFolder = try await WhisperKit.download(
        variant: model.rawValue,
        downloadBase: modelDirectory
      )
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

    guard let whisperKit else {
      throw EditorError.transcriptionFailed
    }
    onStatus("Распознаём речь на устройстве…", nil)
    let options = DecodingOptions(
      detectLanguage: true,
      wordTimestamps: true,
      chunkingStrategy: .vad
    )
    let results: [TranscriptionResult] = try await whisperKit.transcribe(
      audioPath: audioURL.path,
      decodeOptions: options,
      callback: nil
    )

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
