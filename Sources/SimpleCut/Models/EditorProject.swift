@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class EditorProject: ObservableObject {
  @Published var name = "Без названия"
  @Published var canvas: CanvasPreset = .vertical
  @Published var clips: [VideoClip] = []
  @Published var overlays: [OverlayItem] = []
  @Published var waveform: [Float] = []
  @Published var selectedClipID: UUID?
  @Published var selectedOverlayID: UUID?
  @Published var playhead: Double = 0
  @Published var isBusy = false
  @Published var status = "Добавьте видео, чтобы начать"
  @Published var lastError: String?
  @Published var transcriptionModel: TranscriptionModel = .base
  @Published var transcriptionProgress: Double?
  @Published var exportProgress: Double?
  @Published var isTranscribing = false
  @Published var audio = AudioSettings()
  @Published var color = ColorSettings()
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false

  let player = AVPlayer()
  private let transcriptionService = LocalTranscriptionService()
  private var waveformGenerationID = UUID()
  private var undoStack: [ProjectFile] = []
  private var redoStack: [ProjectFile] = []
  private let historyLimit = 100

  var duration: Double {
    clips.reduce(0) { $0 + $1.duration }
  }

  var selectedOverlayIndex: Int? {
    guard let selectedOverlayID else { return nil }
    return overlays.firstIndex { $0.id == selectedOverlayID }
  }

  func reset() {
    if !clips.isEmpty || !overlays.isEmpty {
      recordUndoCheckpoint()
    }
    waveformGenerationID = UUID()
    player.pause()
    player.replaceCurrentItem(with: nil)
    name = "Без названия"
    canvas = .vertical
    clips = []
    overlays = []
    waveform = []
    selectedClipID = nil
    selectedOverlayID = nil
    playhead = 0
    status = "Добавьте видео, чтобы начать"
    lastError = nil
    transcriptionProgress = nil
    exportProgress = nil
    isTranscribing = false
    audio = AudioSettings()
    color = ColorSettings()
  }

  func importVideo(_ url: URL, securityScoped: Bool = false) {
    guard !isBusy else { return }
    let isAccessing = securityScoped
      ? url.startAccessingSecurityScopedResource()
      : false
    isBusy = true
    status = "Импорт видео…"
    Task {
      defer {
        if isAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        isBusy = false
      }
      var storedURL: URL?
      do {
        let importedURL = try await Task.detached(priority: .userInitiated) {
          try MediaLibrary.importVideo(from: url)
        }.value
        storedURL = importedURL
        let asset = AVURLAsset(url: importedURL)
        let assetDuration = try await asset.load(.duration).seconds
        guard assetDuration.isFinite, assetDuration > 0 else {
          throw EditorError.invalidMedia
        }
        guard
          try await !asset.loadTracks(withMediaType: .video).isEmpty
        else {
          throw EditorError.missingVideoTrack
        }
        let clip = VideoClip(
          sourceURL: importedURL,
          sourceStart: 0,
          duration: assetDuration
        )
        recordUndoCheckpoint()
        clips.append(clip)
        selectedClipID = clip.id
        try await rebuildPlayback()
        status = "Видео импортировано"
        generateWaveform()
      } catch {
        if let storedURL {
          try? FileManager.default.removeItem(at: storedURL)
          if clips.last?.sourceURL == storedURL {
            clips.removeLast()
            selectedClipID = clips.last?.id
          }
        }
        lastError = error.localizedDescription
        status = "Ошибка импорта"
      }
    }
  }

  private func generateWaveform() {
    let generationID = UUID()
    waveformGenerationID = generationID
    let currentClips = clips
    Task {
      let samples =
        (try? await WaveformGenerator.samples(
          from: currentClips,
          targetSampleCount: 1_200
        )) ?? []
      guard waveformGenerationID == generationID else { return }
      waveform = samples
      if status == "Видео импортировано" {
        status = "Готово"
      }
    }
  }

  func addText() {
    guard duration > 0 else { return }
    recordUndoCheckpoint()
    let start = min(playhead, duration)
    let item = OverlayItem(
      kind: .text,
      startTime: start,
      duration: max(2, min(5, duration - start)),
      text: "Ваш текст"
    )
    overlays.append(item)
    selectedOverlayID = item.id
  }

  func addImage(_ url: URL) {
    guard duration > 0 else { return }
    do {
      let importedURL = try MediaLibrary.importImage(from: url)
      recordUndoCheckpoint()
      let start = min(playhead, duration)
      let item = OverlayItem(
        kind: .image,
        startTime: start,
        duration: max(0.1, min(5, duration - start)),
        imageURL: importedURL
      )
      overlays.append(item)
      selectedOverlayID = item.id
    } catch {
      lastError = error.localizedDescription
    }
  }

  func generateCaptions() {
    guard !clips.isEmpty, !isTranscribing else { return }
    isTranscribing = true
    isBusy = true
    transcriptionProgress = nil
    status = "Подготавливаем транскрибацию…"
    Task {
      do {
        let drafts = try await transcriptionService.transcribe(
          clips: clips,
          model: transcriptionModel
        ) { [weak self] message, progress in
          self?.status = message
          self?.transcriptionProgress = progress
        }
        recordUndoCheckpoint()
        overlays.removeAll { $0.kind == .caption }
        let captions = drafts.map {
          OverlayItem(
            kind: .caption,
            startTime: $0.startTime,
            duration: max(0.2, $0.endTime - $0.startTime),
            normalizedX: 0.5,
            normalizedY: 0.84,
            normalizedWidth: 0.82,
            text: $0.text,
            fontSize: 58,
            foregroundHex: "#FFFFFF",
            backgroundHex: "#000000B3"
          )
        }
        overlays.append(contentsOf: captions)
        selectedOverlayID = captions.first?.id
        status =
          captions.isEmpty
          ? "Речь не обнаружена"
          : "Создано субтитров: \(captions.count)"
      } catch {
        lastError = error.localizedDescription
        status = "Ошибка транскрибации"
      }
      transcriptionProgress = nil
      isTranscribing = false
      isBusy = false
    }
  }

  func splitAtPlayhead() {
    guard duration > 0 else { return }
    var cursor = 0.0
    for index in clips.indices {
      let end = cursor + clips[index].duration
      if playhead > cursor + 0.04, playhead < end - 0.04 {
        recordUndoCheckpoint()
        let local = playhead - cursor
        let original = clips[index]
        let left = VideoClip(
          sourceURL: original.sourceURL,
          sourceStart: original.sourceStart,
          duration: local
        )
        let right = VideoClip(
          sourceURL: original.sourceURL,
          sourceStart: original.sourceStart + local,
          duration: original.duration - local
        )
        clips.replaceSubrange(index...index, with: [left, right])
        selectedClipID = right.id
        rebuildAfterEdit()
        return
      }
      cursor = end
    }
  }

  func deleteSelectedClip() {
    guard let selectedClipID,
      let index = clips.firstIndex(where: { $0.id == selectedClipID })
    else { return }
    recordUndoCheckpoint()
    let removedStart = clips.prefix(index).reduce(0) { $0 + $1.duration }
    let removedDuration = clips[index].duration
    clips.remove(at: index)
    rippleRemoveOverlays(
      from: removedStart,
      duration: removedDuration
    )
    self.selectedClipID =
      clips.indices.contains(index)
      ? clips[index].id
      : clips.last?.id
    playhead = min(playhead, duration)
    rebuildAfterEdit()
  }

  func trimClip(id: UUID, edge: TrimEdge, by requestedAmount: Double) {
    guard requestedAmount > 0,
      let index = clips.firstIndex(where: { $0.id == id })
    else { return }
    let amount = min(requestedAmount, clips[index].duration - 0.1)
    guard amount > 0 else { return }
    recordUndoCheckpoint()
    let clipStart = clips.prefix(index).reduce(0) { $0 + $1.duration }
    switch edge {
    case .leading:
      clips[index].sourceStart += amount
      clips[index].duration -= amount
      rippleRemoveOverlays(from: clipStart, duration: amount)
      playhead = max(clipStart, playhead - amount)
    case .trailing:
      clips[index].duration -= amount
      rippleRemoveOverlays(
        from: clipStart + clips[index].duration,
        duration: amount
      )
      playhead = min(playhead, duration)
    }
    rebuildAfterEdit()
  }

  func moveClip(id: UUID, before targetID: UUID) {
    guard id != targetID,
      let sourceIndex = clips.firstIndex(where: { $0.id == id }),
      let initialTargetIndex = clips.firstIndex(where: { $0.id == targetID })
    else { return }
    recordUndoCheckpoint()
    let clip = clips.remove(at: sourceIndex)
    let targetIndex =
      sourceIndex < initialTargetIndex
      ? initialTargetIndex - 1
      : initialTargetIndex
    clips.insert(clip, at: targetIndex)
    selectedClipID = id
    rebuildAfterEdit()
  }

  func recordUndoCheckpoint() {
    undoStack.append(projectFile())
    if undoStack.count > historyLimit {
      undoStack.removeFirst(undoStack.count - historyLimit)
    }
    redoStack.removeAll()
    updateHistoryState()
  }

  func undo() {
    guard let snapshot = undoStack.popLast() else { return }
    redoStack.append(projectFile())
    restore(snapshot)
    updateHistoryState()
  }

  func redo() {
    guard let snapshot = redoStack.popLast() else { return }
    undoStack.append(projectFile())
    restore(snapshot)
    updateHistoryState()
  }

  func seek(to time: Double) {
    playhead = min(max(0, time), duration)
    player.seek(
      to: CMTime(seconds: playhead, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  func togglePlayback() {
    if player.timeControlStatus == .playing {
      player.pause()
    } else {
      if playhead >= duration - 0.05 { seek(to: 0) }
      player.play()
    }
  }

  func rebuildPlayback() async throws {
    let composition = try await CompositionBuilder.build(clips: clips, canvas: canvas)
    let item = AVPlayerItem(asset: composition.asset)
    item.videoComposition = composition.videoComposition
    player.replaceCurrentItem(with: item)
    seek(to: min(playhead, duration))
  }

  func saveProject(to url: URL) throws {
    try ProjectPackageService.save(projectFile(), to: url)
    status = "Проект сохранён"
  }

  func loadProject(from url: URL) throws {
    let project = try ProjectPackageService.load(from: url)
    name = project.name
    canvas = project.canvas
    clips = project.clips
    overlays = project.overlays
    audio = project.audio
    color = project.color
    selectedClipID = clips.first?.id
    selectedOverlayID = nil
    playhead = 0
    undoStack.removeAll()
    redoStack.removeAll()
    updateHistoryState()
    rebuildAfterEdit()
  }

  private func projectFile() -> ProjectFile {
    ProjectFile(
      name: name,
      canvas: canvas,
      clips: clips,
      overlays: overlays,
      audio: audio,
      color: color
    )
  }

  private func restore(_ project: ProjectFile) {
    name = project.name
    canvas = project.canvas
    clips = project.clips
    overlays = project.overlays
    audio = project.audio
    color = project.color
    selectedClipID = clips.first?.id
    selectedOverlayID = nil
    playhead = min(playhead, duration)
    rebuildAfterEdit()
  }

  private func updateHistoryState() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }

  private func rebuildAfterEdit() {
    Task {
      do {
        try await rebuildPlayback()
        generateWaveform()
      } catch {
        lastError = error.localizedDescription
        status = "Не удалось обновить монтаж"
      }
    }
  }

  private func rippleRemoveOverlays(from start: Double, duration: Double) {
    let end = start + duration
    overlays = overlays.compactMap { item in
      let itemEnd = item.startTime + item.duration
      if itemEnd <= start {
        return item
      }
      if item.startTime >= end {
        var shifted = item
        shifted.startTime -= duration
        return shifted
      }

      let before = max(0, start - item.startTime)
      let after = max(0, itemEnd - end)
      guard before + after >= 0.1 else { return nil }
      var trimmed = item
      trimmed.duration = before + after
      if before == 0 {
        trimmed.startTime = start
      }
      return trimmed
    }
  }
}

enum EditorError: LocalizedError {
  case invalidMedia
  case missingVideoTrack
  case exportFailed
  case transcriptionFailed

  var errorDescription: String? {
    switch self {
    case .invalidMedia: "Файл не содержит корректного видео"
    case .missingVideoTrack: "В видео отсутствует видеодорожка"
    case .exportFailed: "Не удалось экспортировать видео"
    case .transcriptionFailed: "Не удалось запустить локальную транскрибацию"
    }
  }
}

extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
