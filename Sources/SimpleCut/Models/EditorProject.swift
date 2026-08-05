@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class EditorProject: ObservableObject {
  @Published var name = "Без названия"
  @Published var canvas: CanvasPreset = .vertical
  @Published var scalingMode: VideoScalingMode = .fit
  @Published var clips: [VideoClip] = []
  @Published var overlays: [OverlayItem] = []
  @Published var waveform: [Float] = []
  @Published var selectedClipID: UUID? {
    didSet {
      guard !isSynchronizingClipSelection else { return }
      selectedClipIDs =
        selectedClipID.map { Set([$0]) } ?? []
    }
  }
  @Published private(set) var selectedClipIDs: Set<UUID> = []
  @Published var selectedOverlayID: UUID?
  @Published var playhead: Double = 0
  @Published var timelineZoom = 1.0
  @Published var isBusy = false
  @Published var status = "Добавьте видео, чтобы начать"
  @Published var lastError: String?
  @Published var transcriptionModel: TranscriptionModel = .base
  @Published var transcriptionLanguage: TranscriptionLanguage = .automatic
  @Published var transcriptionProgress: Double?
  @Published var exportProgress: Double?
  @Published var isTranscribing = false
  @Published var audio = AudioSettings()
  @Published var color = ColorSettings()
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var isDirty = false
  @Published private(set) var currentProjectURL: URL?

  let player = AVPlayer()
  private let transcriptionService = LocalTranscriptionService()
  private var waveformGenerationID = UUID()
  private struct HistorySnapshot {
    var project: ProjectFile
    var selectedClipIDs: Set<UUID>
    var selectedClipID: UUID?
    var selectedOverlayID: UUID?
    var playhead: Double
    var timelineZoom: Double
  }

  private var undoStack: [HistorySnapshot] = []
  private var redoStack: [HistorySnapshot] = []
  private let historyLimit = 100
  private var recoveryTask: Task<Void, Never>?
  private var transcriptionTask: Task<Void, Never>?
  private var isSynchronizingClipSelection = false
  private var securityScopedProjectURL: URL?

  init(loadRecovery: Bool = true) {
    guard loadRecovery else { return }
    guard let recovered = try? RecoveryService.load() else { return }
    name = recovered.name
    canvas = recovered.canvas
    scalingMode = recovered.scalingMode
    let validClips = recovered.clips.filter {
      FileManager.default.fileExists(atPath: $0.sourceURL.path)
    }
    let validOverlays = recovered.overlays.filter { item in
      guard item.kind == .image, let imageURL = item.imageURL else {
        return true
      }
      return FileManager.default.fileExists(atPath: imageURL.path)
    }
    clips = validClips
    overlays = Self.sanitizedOverlays(
      validOverlays,
      projectDuration: validClips.reduce(0) { $0 + $1.duration }
    )
    audio = Self.simplifiedAudio(recovered.audio)
    color = recovered.color
    isDirty = true
    status = "Восстановлена несохранённая версия"
    let missingMediaCount =
      recovered.clips.count - validClips.count
      + recovered.overlays.count - validOverlays.count
    if missingMediaCount > 0 {
      lastError =
        "Не удалось восстановить часть медиафайлов (\(missingMediaCount)). "
        + "Они были удалены или перемещены."
    }
  }

  var duration: Double {
    clips.reduce(0) { $0 + $1.duration }
  }

  var selectedOverlayIndex: Int? {
    guard let selectedOverlayID else { return nil }
    return overlays.firstIndex { $0.id == selectedOverlayID }
  }

  var selectedClipIndex: Int? {
    guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else {
      return nil
    }
    return clips.firstIndex { $0.id == id }
  }

  var canSplitAtPlayhead: Bool {
    guard duration > 0 else { return false }
    var cursor = 0.0
    for clip in clips {
      let end = cursor + clip.duration
      if playhead > cursor + 0.04, playhead < end - 0.04 {
        return true
      }
      cursor = end
    }
    return false
  }

  var canJoinSelectedClips: Bool {
    joinableSelection != nil
  }

  func reset() {
    waveformGenerationID = UUID()
    player.pause()
    player.replaceCurrentItem(with: nil)
    name = "Без названия"
    canvas = .vertical
    scalingMode = .fit
    clips = []
    overlays = []
    waveform = []
    selectedClipID = nil
    selectedOverlayID = nil
    playhead = 0
    timelineZoom = 1
    status = "Добавьте видео, чтобы начать"
    lastError = nil
    transcriptionProgress = nil
    exportProgress = nil
    isTranscribing = false
    transcriptionTask?.cancel()
    transcriptionTask = nil
    audio = AudioSettings()
    color = ColorSettings()
    currentProjectURL = nil
    stopAccessingProjectURL()
    isDirty = false
    undoStack.removeAll()
    redoStack.removeAll()
    updateHistoryState()
    recoveryTask?.cancel()
    RecoveryService.clear()
  }

  func importVideo(
    _ url: URL,
    securityScoped: Bool = false,
    copyToLibrary: Bool = true,
    completion: @escaping (Bool) -> Void = { _ in }
  ) {
    guard !isBusy else {
      completion(false)
      return
    }
    let isAccessing =
      securityScoped
      ? url.startAccessingSecurityScopedResource()
      : false
    isBusy = true
    status = "Импорт видео…"
    Task {
      var succeeded = false
      defer {
        if isAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        isBusy = false
        completion(succeeded)
      }
      var storedURL: URL?
      do {
        let importedURL: URL
        if copyToLibrary {
          importedURL = try await Task.detached(priority: .userInitiated) {
            try MediaLibrary.importVideo(from: url)
          }.value
        } else {
          importedURL = url
        }
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
          duration: assetDuration,
          sourceDuration: assetDuration
        )
        recordUndoCheckpoint()
        clips.append(clip)
        selectedClipID = clip.id
        try await rebuildPlayback()
        status = "Видео импортировано"
        generateWaveform()
        succeeded = true
      } catch {
        if let storedURL, copyToLibrary {
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
    let placement = newOverlayPlacement(preferredDuration: 5)
    let item = OverlayItem(
      kind: .text,
      startTime: placement.start,
      duration: placement.duration,
      text: "Ваш текст"
    )
    overlays.append(item)
    selectedOverlayID = item.id
  }

  func addImage(_ url: URL, securityScoped: Bool = false) {
    guard duration > 0 else { return }
    let isAccessing =
      securityScoped
      ? url.startAccessingSecurityScopedResource()
      : false
    defer {
      if isAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    do {
      let importedURL = try MediaLibrary.importImage(from: url)
      recordUndoCheckpoint()
      let placement = newOverlayPlacement(preferredDuration: 5)
      let item = OverlayItem(
        kind: .image,
        startTime: placement.start,
        duration: placement.duration,
        imageURL: importedURL
      )
      overlays.append(item)
      selectedOverlayID = item.id
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func newOverlayPlacement(
    preferredDuration: Double
  ) -> (start: Double, duration: Double) {
    let minimumDuration = min(0.1, duration)
    let start = min(max(0, playhead), max(0, duration - minimumDuration))
    return (start, min(preferredDuration, max(minimumDuration, duration - start)))
  }

  func generateCaptions() {
    guard !clips.isEmpty, !isTranscribing else { return }
    isTranscribing = true
    isBusy = true
    transcriptionProgress = nil
    status = "Подготавливаем транскрибацию…"
    transcriptionTask = Task {
      defer {
        transcriptionProgress = nil
        isTranscribing = false
        isBusy = false
        transcriptionTask = nil
      }
      do {
        let drafts = try await transcriptionService.transcribe(
          clips: clips,
          model: transcriptionModel,
          language: transcriptionLanguage
        ) { [weak self] message, progress in
          self?.status = message
          self?.transcriptionProgress = progress
        }
        recordUndoCheckpoint()
        let captions = replaceCaptions(with: drafts)
        status =
          captions.isEmpty
          ? "Речь не обнаружена"
          : "Создано субтитров: \(captions.count)"
      } catch is CancellationError {
        status = "Создание субтитров отменено"
      } catch {
        lastError = error.localizedDescription
        status = "Ошибка транскрибации"
      }
    }
  }

  func cancelTranscription() {
    guard isTranscribing else { return }
    status = "Отменяем создание субтитров…"
    transcriptionTask?.cancel()
  }

  @discardableResult
  func replaceCaptions(with drafts: [CaptionDraft]) -> [OverlayItem] {
    overlays.removeAll { $0.kind == .caption }
    let captions = drafts.compactMap { draft -> OverlayItem? in
      let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let start = min(duration, max(0, draft.startTime))
      let end = min(duration, max(0, draft.endTime))
      guard !text.isEmpty, start < duration, end - start >= 0.05 else {
        return nil
      }
      return OverlayItem(
        kind: .caption,
        startTime: start,
        duration: end - start,
        normalizedX: 0.5,
        normalizedY: 0.84,
        normalizedWidth: 0.82,
        text: text,
        fontSize: 58,
        foregroundHex: "#FFFFFF",
        backgroundHex: "#000000B3"
      )
    }
    overlays.append(contentsOf: captions)
    selectedOverlayID = captions.first?.id
    if let first = captions.first {
      clearClipSelection()
      seek(to: first.startTime)
    }
    return captions
  }

  func setOverlayStart(id: UUID, to requestedStart: Double) {
    guard let index = overlays.firstIndex(where: { $0.id == id }) else {
      return
    }
    let maximumStart = max(0, duration - 0.1)
    let start = min(max(0, requestedStart), maximumStart)
    overlays[index].startTime = start
    overlays[index].duration = min(
      overlays[index].duration,
      max(0.1, duration - start)
    )
    selectedOverlayID = id
    markDirty()
  }

  func moveOverlay(id: UUID, by delta: Double) {
    guard let item = overlays.first(where: { $0.id == id }) else { return }
    setOverlayStart(
      id: id,
      to: min(
        max(0, item.startTime + delta),
        max(0, duration - item.duration)
      )
    )
  }

  func setOverlayDuration(id: UUID, to requestedDuration: Double) {
    guard let index = overlays.firstIndex(where: { $0.id == id }) else {
      return
    }
    overlays[index].duration = min(
      max(0.1, requestedDuration),
      max(0.1, duration - overlays[index].startTime)
    )
    selectedOverlayID = id
    markDirty()
  }

  func resizeOverlay(id: UUID, edge: TrimEdge, by requestedDelta: Double) {
    guard let index = overlays.firstIndex(where: { $0.id == id }) else {
      return
    }
    let item = overlays[index]
    switch edge {
    case .leading:
      let delta = min(
        max(requestedDelta, -item.startTime),
        item.duration - 0.1
      )
      overlays[index].startTime += delta
      overlays[index].duration -= delta
    case .trailing:
      let delta = min(
        max(requestedDelta, -(item.duration - 0.1)),
        duration - item.startTime - item.duration
      )
      overlays[index].duration += delta
    }
    selectedOverlayID = id
    markDirty()
  }

  func splitAtPlayhead() {
    guard canSplitAtPlayhead else {
      status = "Переместите курсор внутрь фрагмента, чтобы разрезать"
      return
    }
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
          duration: local,
          sourceDuration: original.sourceDuration
        )
        let right = VideoClip(
          sourceURL: original.sourceURL,
          sourceStart: original.sourceStart + local,
          duration: original.duration - local,
          sourceDuration: original.sourceDuration
        )
        clips.replaceSubrange(index...index, with: [left, right])
        selectedClipID = right.id
        rebuildAfterEdit()
        return
      }
      cursor = end
    }
  }

  func joinSelectedClips() {
    guard let selection = joinableSelection else {
      status =
        "Можно объединить только соседние фрагменты одного исходника без пропусков"
      return
    }
    recordUndoCheckpoint()
    let firstClip = clips[selection.lowerBound]
    let joined = VideoClip(
      sourceURL: firstClip.sourceURL,
      sourceStart: firstClip.sourceStart,
      duration: selection.reduce(0) { $0 + clips[$1].duration },
      sourceDuration: firstClip.sourceDuration
    )
    clips.replaceSubrange(selection, with: [joined])
    setClipSelection([joined.id], primary: joined.id)
    status = "Фрагменты объединены"
    rebuildAfterEdit()
  }

  func deleteSelectedClip() {
    deleteSelectedClips()
  }

  func deleteSelectedClips() {
    let selectedIDs =
      selectedClipIDs.isEmpty
      ? selectedClipID.map { Set([$0]) } ?? []
      : selectedClipIDs
    let selectedIndices = clips.indices.filter {
      selectedIDs.contains(clips[$0].id)
    }
    guard !selectedIndices.isEmpty else { return }
    recordUndoCheckpoint()
    let oldPlayhead = playhead
    var cursor = 0.0
    var removedRanges: [(start: Double, duration: Double)] = []
    for clip in clips {
      if selectedIDs.contains(clip.id) {
        removedRanges.append((cursor, clip.duration))
      }
      cursor += clip.duration
    }
    let removedBeforePlayhead = removedRanges.reduce(0.0) { result, range in
      result
        + min(max(0, oldPlayhead - range.start), range.duration)
    }
    let firstRemovedIndex = selectedIndices[0]
    clips.removeAll { selectedIDs.contains($0.id) }
    for range in removedRanges.reversed() {
      rippleRemoveOverlays(from: range.start, duration: range.duration)
    }
    let nextSelection =
      clips.indices.contains(firstRemovedIndex)
      ? clips[firstRemovedIndex].id
      : clips.last?.id
    setClipSelection(nextSelection.map { Set([$0]) } ?? [], primary: nextSelection)
    playhead = oldPlayhead - removedBeforePlayhead
    playhead = min(playhead, duration)
    rebuildAfterEdit()
  }

  func trimClip(id: UUID, edge: TrimEdge, by requestedAmount: Double) {
    let delta = edge == .leading ? requestedAmount : -requestedAmount
    resizeClip(id: id, edge: edge, by: delta)
  }

  func resizeClip(id: UUID, edge: TrimEdge, by requestedDelta: Double) {
    guard let index = clips.firstIndex(where: { $0.id == id }) else {
      return
    }
    let clip = clips[index]
    let minimumDelta: Double
    let maximumDelta: Double
    switch edge {
    case .leading:
      minimumDelta = -clip.sourceStart
      maximumDelta = clip.duration - 0.1
    case .trailing:
      minimumDelta = -(clip.duration - 0.1)
      maximumDelta = max(
        0,
        (clip.sourceDuration ?? clip.sourceEnd) - clip.sourceEnd
      )
    }
    let delta = min(max(requestedDelta, minimumDelta), maximumDelta)
    guard abs(delta) > 0.0001 else { return }
    recordUndoCheckpoint()
    let clipStart = clips.prefix(index).reduce(0) { $0 + $1.duration }
    switch edge {
    case .leading:
      clips[index].sourceStart += delta
      clips[index].duration -= delta
      if delta > 0 {
        rippleRemoveOverlays(from: clipStart, duration: delta)
        playhead = max(clipStart, playhead - delta)
      } else {
        rippleInsertOverlays(at: clipStart, duration: -delta)
        if playhead >= clipStart {
          playhead += -delta
        }
      }
    case .trailing:
      let oldEnd = clipStart + clips[index].duration
      clips[index].duration += delta
      if delta < 0 {
        rippleRemoveOverlays(
          from: clipStart + clips[index].duration,
          duration: -delta
        )
        playhead = min(playhead, duration)
      } else {
        rippleInsertOverlays(at: oldEnd, duration: delta)
        if playhead >= oldEnd {
          playhead += delta
        }
      }
    }
    setClipSelection([id], primary: id)
    rebuildAfterEdit()
  }

  func selectClip(
    id: UUID,
    extending: Bool = false,
    range: Bool = false
  ) {
    guard clips.contains(where: { $0.id == id }) else { return }
    if range, let selectedClipID,
      let anchor = clips.firstIndex(where: { $0.id == selectedClipID }),
      let target = clips.firstIndex(where: { $0.id == id })
    {
      let bounds = min(anchor, target)...max(anchor, target)
      setClipSelection(
        Set(bounds.map { clips[$0].id }),
        primary: id
      )
    } else if extending {
      var selection = selectedClipIDs
      if selection.contains(id) {
        selection.remove(id)
      } else {
        selection.insert(id)
      }
      let primary =
        selection.contains(id)
        ? id
        : clips.first(where: { selection.contains($0.id) })?.id
      setClipSelection(selection, primary: primary)
    } else {
      setClipSelection([id], primary: id)
    }
  }

  func selectAllClips() {
    setClipSelection(Set(clips.map(\.id)), primary: clips.first?.id)
  }

  func clearClipSelection() {
    setClipSelection([], primary: nil)
  }

  func isClipSelected(_ id: UUID) -> Bool {
    selectedClipIDs.contains(id)
  }

  private func setClipSelection(
    _ selection: Set<UUID>,
    primary: UUID?
  ) {
    isSynchronizingClipSelection = true
    selectedClipIDs = selection
    selectedClipID = primary
    isSynchronizingClipSelection = false
    if !selection.isEmpty {
      selectedOverlayID = nil
    }
  }

  private var joinableSelection: ClosedRange<Int>? {
    let indices = clips.indices.filter { selectedClipIDs.contains(clips[$0].id) }
    guard indices.count >= 2,
      let first = indices.first,
      let last = indices.last,
      indices == Array(first...last)
    else { return nil }

    let sourceURL = clips[first].sourceURL.standardizedFileURL
    for index in (first + 1)...last {
      let previous = clips[index - 1]
      let current = clips[index]
      guard current.sourceURL.standardizedFileURL == sourceURL,
        abs(previous.sourceEnd - current.sourceStart) < 0.002
      else { return nil }
    }
    return first...last
  }

  func canRollEdit(atBoundary boundaryIndex: Int) -> Bool {
    guard boundaryIndex > 0, clips.indices.contains(boundaryIndex) else {
      return false
    }
    let left = clips[boundaryIndex - 1]
    let right = clips[boundaryIndex]
    return left.sourceURL.standardizedFileURL
      == right.sourceURL.standardizedFileURL
      && abs(left.sourceEnd - right.sourceStart) < 0.002
  }

  @discardableResult
  func rollEdit(atBoundary boundaryIndex: Int, by requestedDelta: Double) -> Bool {
    guard canRollEdit(atBoundary: boundaryIndex) else { return false }
    let leftIndex = boundaryIndex - 1
    let minimumDuration = 0.1
    let minimumDelta = minimumDuration - clips[leftIndex].duration
    let maximumDelta = clips[boundaryIndex].duration - minimumDuration
    let delta = min(max(requestedDelta, minimumDelta), maximumDelta)
    guard abs(delta) > 0.0001 else { return false }

    recordUndoCheckpoint()
    clips[leftIndex].duration += delta
    clips[boundaryIndex].sourceStart += delta
    clips[boundaryIndex].duration -= delta
    selectedClipID = clips[boundaryIndex].id
    rebuildAfterEdit()
    return true
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

  func moveClip(id: UUID, by offset: Int) {
    guard let sourceIndex = clips.firstIndex(where: { $0.id == id }) else {
      return
    }
    let targetIndex = min(clips.count - 1, max(0, sourceIndex + offset))
    guard targetIndex != sourceIndex else { return }
    recordUndoCheckpoint()
    let clip = clips.remove(at: sourceIndex)
    clips.insert(clip, at: targetIndex)
    selectedClipID = id
    rebuildAfterEdit()
  }

  func recordUndoCheckpoint() {
    undoStack.append(historySnapshot())
    if undoStack.count > historyLimit {
      undoStack.removeFirst(undoStack.count - historyLimit)
    }
    redoStack.removeAll()
    updateHistoryState()
    markDirty()
  }

  func undo() {
    guard let snapshot = undoStack.popLast() else { return }
    redoStack.append(historySnapshot())
    restore(snapshot)
    updateHistoryState()
    markDirty()
  }

  func redo() {
    guard let snapshot = redoStack.popLast() else { return }
    undoStack.append(historySnapshot())
    restore(snapshot)
    updateHistoryState()
    markDirty()
  }

  func seek(to time: Double) {
    playhead = min(max(0, time), duration)
    player.seek(
      to: CMTime(seconds: playhead, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  func seek(by offset: Double) {
    seek(to: playhead + offset)
  }

  var timelineNavigationStep: Double {
    1.0 / (30 * max(1, timelineZoom))
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
    let composition = try await CompositionBuilder.build(
      clips: clips,
      canvas: canvas,
      scalingMode: scalingMode
    )
    let item = AVPlayerItem(asset: composition.asset)
    item.videoComposition = composition.videoComposition
    player.replaceCurrentItem(with: item)
    seek(to: min(playhead, duration))
  }

  func preparePlayback() async throws {
    await hydrateSourceDurations()
    try await rebuildPlayback()
    generateWaveform()
  }

  func saveProject(to url: URL) throws {
    try ProjectPackageService.save(projectFile(), to: url)
    currentProjectURL = url
    isDirty = false
    recoveryTask?.cancel()
    RecoveryService.clear()
    status = "Проект сохранён"
  }

  func loadProject(from url: URL, securityScoped: Bool = false) throws {
    let isAccessing =
      securityScoped
      ? url.startAccessingSecurityScopedResource()
      : false
    do {
      let project = try ProjectPackageService.load(from: url)
      stopAccessingProjectURL()
      securityScopedProjectURL = isAccessing ? url : nil
      name = project.name
      canvas = project.canvas
      scalingMode = project.scalingMode
      clips = project.clips
      overlays = Self.sanitizedOverlays(
        project.overlays,
        projectDuration: project.clips.reduce(0) { $0 + $1.duration }
      )
      audio = Self.simplifiedAudio(project.audio)
      color = project.color
      selectedClipID = clips.first?.id
      selectedOverlayID = nil
      playhead = 0
      undoStack.removeAll()
      redoStack.removeAll()
      updateHistoryState()
      currentProjectURL = url
      isDirty = false
      recoveryTask?.cancel()
      RecoveryService.clear()
      rebuildAfterEdit()
    } catch {
      if isAccessing {
        url.stopAccessingSecurityScopedResource()
      }
      throw error
    }
  }

  private func stopAccessingProjectURL() {
    securityScopedProjectURL?.stopAccessingSecurityScopedResource()
    securityScopedProjectURL = nil
  }

  private static func sanitizedOverlays(
    _ items: [OverlayItem],
    projectDuration: Double
  ) -> [OverlayItem] {
    guard projectDuration > 0 else { return [] }
    return items.compactMap { item in
      var sanitized = item
      let minimumDuration = min(0.1, projectDuration)
      sanitized.startTime = min(
        max(0, item.startTime),
        max(0, projectDuration - minimumDuration)
      )
      sanitized.duration = min(
        max(minimumDuration, item.duration),
        projectDuration - sanitized.startTime
      )
      guard sanitized.duration > 0 else { return nil }
      return sanitized
    }
  }

  private static func simplifiedAudio(
    _ settings: AudioSettings
  ) -> AudioSettings {
    AudioSettings(normalizeLoudness: settings.normalizeLoudness)
  }

  private func projectFile() -> ProjectFile {
    ProjectFile(
      name: name,
      canvas: canvas,
      scalingMode: scalingMode,
      clips: clips,
      overlays: overlays,
      audio: audio,
      color: color
    )
  }

  private func historySnapshot() -> HistorySnapshot {
    HistorySnapshot(
      project: projectFile(),
      selectedClipIDs: selectedClipIDs,
      selectedClipID: selectedClipID,
      selectedOverlayID: selectedOverlayID,
      playhead: playhead,
      timelineZoom: timelineZoom
    )
  }

  private func restore(_ snapshot: HistorySnapshot) {
    let project = snapshot.project
    name = project.name
    canvas = project.canvas
    scalingMode = project.scalingMode
    clips = project.clips
    overlays = project.overlays
    audio = project.audio
    color = project.color
    let availableClipIDs = Set(clips.map(\.id))
    let restoredClipIDs = snapshot.selectedClipIDs.intersection(availableClipIDs)
    let restoredPrimary =
      snapshot.selectedClipID.flatMap { availableClipIDs.contains($0) ? $0 : nil }
    setClipSelection(restoredClipIDs, primary: restoredPrimary)
    selectedOverlayID = snapshot.selectedOverlayID.flatMap { id in
      overlays.contains(where: { $0.id == id }) ? id : nil
    }
    playhead = min(max(0, snapshot.playhead), duration)
    timelineZoom = min(64, max(1, snapshot.timelineZoom))
    rebuildAfterEdit()
  }

  private func updateHistoryState() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }

  private func markDirty() {
    isDirty = true
    recoveryTask?.cancel()
    recoveryTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled, let self else { return }
      do {
        try RecoveryService.save(self.projectFile())
      } catch {
        self.lastError = "Не удалось сохранить автовосстановление: \(error.localizedDescription)"
      }
    }
  }

  private func rebuildAfterEdit() {
    Task {
      do {
        await hydrateSourceDurations()
        try await rebuildPlayback()
        generateWaveform()
      } catch {
        lastError = error.localizedDescription
        status = "Не удалось обновить монтаж"
      }
    }
  }

  private func hydrateSourceDurations() async {
    let missingURLs = Set(
      clips.compactMap { clip in
        clip.sourceDuration == nil ? clip.sourceURL : nil
      }
    )
    guard !missingURLs.isEmpty else { return }
    var durations: [URL: Double] = [:]
    for url in missingURLs {
      let seconds =
        try? await AVURLAsset(url: url).load(.duration).seconds
      if let seconds, seconds.isFinite, seconds > 0 {
        durations[url] = seconds
      }
    }
    guard !durations.isEmpty else { return }
    for index in clips.indices where clips[index].sourceDuration == nil {
      clips[index].sourceDuration = durations[clips[index].sourceURL]
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

  private func rippleInsertOverlays(at time: Double, duration: Double) {
    guard duration > 0 else { return }
    overlays = overlays.map { item in
      guard item.startTime >= time else { return item }
      var shifted = item
      shifted.startTime += duration
      return shifted
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
