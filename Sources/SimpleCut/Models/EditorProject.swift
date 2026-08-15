@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class EditorProject: ObservableObject {
  @Published var name: String
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
  @Published private(set) var inspectorFocusRequestID = UUID()
  let playback = PlaybackState()
  @Published var timelineZoom = 1.0
  @Published var isBusy = false
  @Published var status = "Добавьте видео, чтобы начать"
  @Published var lastError: String?
  @Published var transcriptionModel: TranscriptionModel = .accurate
  @Published var transcriptionLanguage: TranscriptionLanguage = .automatic
  @Published var transcriptionProgress: Double?
  @Published var exportProgress: Double?
  @Published var isTranscribing = false
  @Published private(set) var isAnalyzingColor = false
  @Published var audio = AudioSettings()
  @Published var color = ColorSettings()
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var isDirty = false
  @Published private(set) var currentProjectURL: URL?
  @Published private(set) var savedCaptionStyles: [NamedOverlayStyle] = []
  @Published private(set) var savedTextStyles: [NamedOverlayStyle] = []

  let player = AVPlayer()
  private let transcriptionService = LocalTranscriptionService()
  private let captionStyleDefaults: UserDefaults
  private let now: () -> Date
  private let namingTimeZone: TimeZone
  private var waveformGenerationID = UUID()
  private var waveformClips: [VideoClip] = []
  private var playbackGenerationID = UUID()
  private var colorAnalysisGenerationID = UUID()
  private var previewAudioURL: URL?
  private var resumePlaybackAfterAudioRebuild = false
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
  private var colorAnalysisTask: Task<Void, Never>?
  private var waveformTask: Task<Void, Never>?
  private var playbackRebuildTask: Task<Void, Never>?
  private struct PendingSeek {
    var time: CMTime
    var toleranceBefore: CMTime
    var toleranceAfter: CMTime
  }
  private var pendingSeek: PendingSeek?
  private var isSeekInProgress = false
  private var seekGeneration = 0
  private var isSynchronizingClipSelection = false
  private var securityScopedProjectURL: URL?

  init(
    loadRecovery: Bool = true,
    captionStyleDefaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    namingTimeZone: TimeZone = .current
  ) {
    self.name = Self.defaultName(for: now(), timeZone: namingTimeZone)
    self.captionStyleDefaults = captionStyleDefaults
    self.now = now
    self.namingTimeZone = namingTimeZone
    savedCaptionStyles = CaptionStyleStore.namedStyles(
      for: .caption,
      in: captionStyleDefaults
    )
    savedTextStyles = CaptionStyleStore.namedStyles(
      for: .text,
      in: captionStyleDefaults
    )
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

  var playhead: Double {
    get { playback.playhead }
    set { playback.playhead = newValue }
  }

  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Без названия" : trimmed
  }

  static func defaultName(
    for date: Date,
    timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH-mm"
    return "Видео \(formatter.string(from: date))"
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

  var canDeleteCurrentCaptionStyle: Bool {
    guard
      let item = overlays.first(where: { $0.kind == .caption }),
      canDeleteSavedStyle(for: item.id)
    else { return false }
    return true
  }

  var hasSavedCaptionStyle: Bool {
    !savedCaptionStyles.isEmpty
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
    playbackGenerationID = UUID()
    player.pause()
    playback.isPlaying = false
    resetPendingSeeks()
    player.replaceCurrentItem(with: nil)
    discardPreviewAudio()
    name = Self.defaultName(for: now(), timeZone: namingTimeZone)
    canvas = .vertical
    scalingMode = .fit
    clips = []
    overlays = []
    waveform = []
    waveformClips = []
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
    colorAnalysisTask?.cancel()
    colorAnalysisGenerationID = UUID()
    colorAnalysisTask = nil
    isAnalyzingColor = false
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
        synchronizeWaveformPreview()
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
    waveformTask?.cancel()
    let generationID = UUID()
    waveformGenerationID = generationID
    let currentClips = clips
    waveformTask = Task {
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      let samples =
        (try? await WaveformGenerator.samples(
          from: currentClips,
          targetSampleCount: 76_800
        )) ?? []
      guard !Task.isCancelled, waveformGenerationID == generationID else {
        return
      }
      waveform = samples
      waveformClips = currentClips
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
    clearClipSelection()
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

  func deleteAllCaptions() {
    guard overlays.contains(where: { $0.kind == .caption }) else { return }
    recordUndoCheckpoint()
    overlays.removeAll { $0.kind == .caption }
    if selectedOverlayID.flatMap({
      id in overlays.first(where: { $0.id == id })
    }) == nil {
      selectedOverlayID = nil
    }
    status = "Субтитры удалены"
  }

  @discardableResult
  func replaceCaptions(with drafts: [CaptionDraft]) -> [OverlayItem] {
    let style =
      overlays.first(where: { $0.kind == .caption }).map(CaptionStyle.init)
      ?? CaptionStyleStore.activeStyle(in: captionStyleDefaults)
        .adaptingBuiltInPosition(to: canvas)
    overlays.removeAll { $0.kind == .caption }
    let captions = drafts.compactMap { draft -> OverlayItem? in
      let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let start = min(duration, max(0, draft.startTime))
      let end = min(duration, max(0, draft.endTime))
      guard !text.isEmpty, start < duration, end - start >= 0.05 else {
        return nil
      }
      var item = OverlayItem(
        kind: .caption,
        startTime: start,
        duration: end - start,
        text: text
      )
      style.apply(to: &item)
      return item
    }
    overlays.append(contentsOf: captions)
    selectedOverlayID = captions.first?.id
    if let first = captions.first {
      clearClipSelection()
      seek(to: first.startTime)
    }
    return captions
  }

  func selectOverlay(id: UUID, seekToStart: Bool = false) {
    guard let item = overlays.first(where: { $0.id == id }) else { return }
    clearClipSelection()
    selectedOverlayID = id
    inspectorFocusRequestID = UUID()
    if seekToStart {
      seek(to: item.startTime)
    }
  }

  func applySelectedCaptionStyleToAll() {
    guard
      let selectedOverlayIndex,
      overlays[selectedOverlayIndex].kind == .caption
    else { return }
    recordUndoCheckpoint()
    let source = overlays[selectedOverlayIndex]
    for index in overlays.indices where overlays[index].kind == .caption {
      overlays[index].fontSize = source.fontSize
      overlays[index].fontName = source.fontName
      overlays[index].fontWeight = source.fontWeight
      overlays[index].textAlignment = source.textAlignment
      overlays[index].foregroundHex = source.foregroundHex
      overlays[index].backgroundHex = source.backgroundHex
      overlays[index].strokeHex = source.strokeHex
      overlays[index].strokeWidth = source.strokeWidth
      overlays[index].textPadding = source.textPadding
      overlays[index].cornerRadius = source.cornerRadius
      overlays[index].normalizedX = source.normalizedX
      overlays[index].normalizedY = source.normalizedY
      overlays[index].normalizedWidth = source.normalizedWidth
    }
  }

  func setCaptionPosition(normalizedX: Double, normalizedY: Double) {
    let x = min(1, max(0, normalizedX))
    let y = min(1, max(0, normalizedY))
    for index in overlays.indices where overlays[index].kind == .caption {
      overlays[index].normalizedX = x
      overlays[index].normalizedY = y
    }
  }

  func setOverlayWidth(id: UUID, normalizedWidth: Double) {
    guard let item = overlays.first(where: { $0.id == id }) else { return }
    let width = min(1, max(0.1, normalizedWidth))
    if item.kind == .caption {
      for index in overlays.indices where overlays[index].kind == .caption {
        overlays[index].normalizedWidth = width
      }
    } else if let index = overlays.firstIndex(where: { $0.id == id }) {
      overlays[index].normalizedWidth = width
    }
  }

  func applyCaptionPreset(_ preset: CaptionStylePreset) {
    guard let id = overlays.first(where: { $0.kind == .caption })?.id else {
      return
    }
    applyStyle(preset.style, to: id)
    CaptionStyleStore.select(preset: preset, in: captionStyleDefaults)
  }

  func applySavedCaptionStyle() {
    guard
      let id = overlays.first(where: { $0.kind == .caption })?.id,
      let name =
        savedCaptionStyles.first(where: { $0.name == "Мой стиль" })?.name
        ?? savedCaptionStyles.first?.name
    else { return }
    applySavedStyle(named: name, to: id)
  }

  func saveCurrentCaptionStyle() {
    guard
      let id = overlays.first(where: { $0.kind == .caption })?.id
    else { return }
    saveStyle(named: "Мой стиль", from: id)
  }

  func applyPreset(_ preset: CaptionStylePreset, to id: UUID) {
    applyStyle(preset.style, to: id)
  }

  func styles(for kind: OverlayKind) -> [NamedOverlayStyle] {
    kind == .caption ? savedCaptionStyles : savedTextStyles
  }

  func applySavedStyle(named name: String, to id: UUID) {
    guard
      let item = overlays.first(where: { $0.id == id }),
      let style = styles(for: item.kind).first(where: {
        $0.name == name
      })?.style
    else { return }
    applyStyle(style, to: id)
    if item.kind == .caption {
      CaptionStyleStore.select(
        style: style,
        in: captionStyleDefaults
      )
    }
  }

  func applySavedStyle(to id: UUID) {
    guard
      let item = overlays.first(where: { $0.id == id }),
      let name =
        styles(for: item.kind).first(where: {
          $0.name == "Мой стиль"
        })?.name
        ?? styles(for: item.kind).first?.name
    else { return }
    applySavedStyle(named: name, to: id)
  }

  func saveStyle(named name: String, from id: UUID) {
    guard let item = overlays.first(where: { $0.id == id }) else { return }
    let style = CaptionStyle(item: item)
    CaptionStyleStore.saveNamed(
      style,
      name: name,
      for: item.kind,
      in: captionStyleDefaults
    )
    if item.kind == .caption {
      CaptionStyleStore.select(
        style: style,
        in: captionStyleDefaults
      )
    }
    refreshSavedStyles()
  }

  func saveStyle(from id: UUID) {
    saveStyle(named: "Мой стиль", from: id)
  }

  func canDeleteSavedStyle(for id: UUID) -> Bool {
    guard
      let item = overlays.first(where: { $0.id == id }),
      styles(for: item.kind).contains(where: {
        $0.style == CaptionStyle(item: item)
      })
    else { return false }
    return true
  }

  func deleteStyle(named name: String, for kind: OverlayKind) {
    CaptionStyleStore.deleteNamed(
      name: name,
      for: kind,
      in: captionStyleDefaults
    )
    refreshSavedStyles()
  }

  func deleteSavedCaptionStyle() {
    CaptionStyleStore.deleteAllNamed(
      for: .caption,
      in: captionStyleDefaults
    )
    CaptionStyleStore.select(
      preset: .classic,
      in: captionStyleDefaults
    )
    refreshSavedStyles()
  }

  private func refreshSavedStyles() {
    savedCaptionStyles = CaptionStyleStore.namedStyles(
      for: .caption,
      in: captionStyleDefaults
    )
    savedTextStyles = CaptionStyleStore.namedStyles(
      for: .text,
      in: captionStyleDefaults
    )
  }

  private func applyStyle(_ style: CaptionStyle, to id: UUID) {
    guard let item = overlays.first(where: { $0.id == id }) else { return }
    let indices =
      item.kind == .caption
      ? overlays.indices.filter { overlays[$0].kind == .caption }
      : overlays.indices.filter { overlays[$0].id == id }
    guard !indices.isEmpty else { return }
    recordUndoCheckpoint()
    for index in indices {
      style.apply(to: &overlays[index])
    }
  }

  func deleteSelectedOverlay() {
    guard let selectedOverlayID else { return }
    guard overlays.contains(where: { $0.id == selectedOverlayID }) else {
      self.selectedOverlayID = nil
      return
    }
    recordUndoCheckpoint()
    overlays.removeAll { $0.id == selectedOverlayID }
    self.selectedOverlayID = nil
  }

  func splitCaptionsIntoWords() {
    let captions = overlays.filter { $0.kind == .caption }
    guard !captions.isEmpty else { return }
    recordUndoCheckpoint()
    var replacements: [OverlayItem] = []
    for caption in captions {
      let words = caption.text?
        .split(whereSeparator: \.isWhitespace)
        .map(String.init) ?? []
      guard words.count > 1 else {
        replacements.append(caption)
        continue
      }
      let weights = words.map { max(1, $0.count) }
      let totalWeight = max(1, weights.reduce(0, +))
      var cursor = caption.startTime
      for (word, weight) in zip(words, weights) {
        var item = caption
        item.id = UUID()
        item.text = word
        item.startTime = cursor
        item.duration = caption.duration * Double(weight) / Double(totalWeight)
        cursor += item.duration
        replacements.append(item)
      }
      if let lastIndex = replacements.indices.last {
        replacements[lastIndex].duration =
          caption.startTime + caption.duration
          - replacements[lastIndex].startTime
      }
    }
    overlays.removeAll { $0.kind == .caption }
    overlays.append(contentsOf: replacements)
    overlays.sort {
      if $0.startTime == $1.startTime {
        return $0.kind.rawValue < $1.kind.rawValue
      }
      return $0.startTime < $1.startTime
    }
    selectedOverlayID = replacements.first?.id
    if let first = replacements.first {
      seek(to: first.startTime)
    }
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
    if clips.isEmpty {
      clearPlaybackForEmptyProject()
    } else {
      rebuildAfterEdit()
    }
  }

  func trimClip(id: UUID, edge: TrimEdge, by requestedAmount: Double) {
    let delta = edge == .leading ? requestedAmount : -requestedAmount
    resizeClip(id: id, edge: edge, by: delta)
  }

  func resizeClip(id: UUID, edge: TrimEdge, by requestedDelta: Double) {
    guard let delta = clampedResizeDelta(
      id: id,
      edge: edge,
      requestedDelta: requestedDelta
    ), abs(delta) > 0.0001
    else { return }
    recordUndoCheckpoint()
    applyClipResize(id: id, edge: edge, requestedDelta: requestedDelta)
    rebuildAfterEdit()
  }

  private func clampedResizeDelta(
    id: UUID,
    edge: TrimEdge,
    requestedDelta: Double
  ) -> Double? {
    guard let index = clips.firstIndex(where: { $0.id == id }) else {
      return nil
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
    return min(max(requestedDelta, minimumDelta), maximumDelta)
  }

  private func applyClipResize(
    id: UUID,
    edge: TrimEdge,
    requestedDelta: Double
  ) {
    guard let index = clips.firstIndex(where: { $0.id == id }),
      let delta = clampedResizeDelta(
        id: id,
        edge: edge,
        requestedDelta: requestedDelta
      ), abs(delta) > 0.0001
    else { return }
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
    seek(to: time, tolerance: .zero)
  }

  /// Seeks responsively while a pointer is moving. The final committed seek
  /// still uses zero tolerance through `seek(to:)`.
  func scrub(to time: Double) {
    let frame = CMTime(value: 1, timescale: 30)
    seek(to: time, tolerance: frame)
  }

  private func seek(to time: Double, tolerance: CMTime) {
    playhead = min(max(0, time), duration)
    let previewTime = Self.previewTime(
      for: playhead,
      duration: duration
    )
    requestPlayerSeek(
      PendingSeek(
        time: CMTime(seconds: previewTime, preferredTimescale: 600),
        toleranceBefore: tolerance,
        toleranceAfter: tolerance
      )
    )
  }

  private func requestPlayerSeek(_ seek: PendingSeek) {
    guard player.currentItem != nil else { return }
    pendingSeek = seek
    performNextSeekIfNeeded()
  }

  private func performNextSeekIfNeeded() {
    guard !isSeekInProgress, let seek = pendingSeek else { return }
    pendingSeek = nil
    isSeekInProgress = true
    let generation = seekGeneration
    player.seek(
      to: seek.time,
      toleranceBefore: seek.toleranceBefore,
      toleranceAfter: seek.toleranceAfter
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.seekGeneration == generation else { return }
        self.isSeekInProgress = false
        self.performNextSeekIfNeeded()
      }
    }
  }

  private func resetPendingSeeks() {
    seekGeneration += 1
    pendingSeek = nil
    isSeekInProgress = false
    player.currentItem?.cancelPendingSeeks()
  }

  nonisolated static func previewTime(
    for playhead: Double,
    duration: Double,
    frameDuration: Double = 1.0 / 30.0
  ) -> Double {
    let clamped = min(max(0, playhead), max(0, duration))
    guard duration > 0, clamped >= duration - 0.0001 else {
      return clamped
    }
    return max(0, duration - frameDuration)
  }

  func seek(by offset: Double) {
    seek(to: playhead + offset)
  }

  func seekToPreviousEdit() {
    let threshold = playhead - 0.001
    let boundary = editBoundaries.last(where: { $0 < threshold }) ?? 0
    seek(to: boundary)
  }

  func seekToNextEdit() {
    let threshold = playhead + 0.001
    let boundary = editBoundaries.first(where: { $0 > threshold }) ?? duration
    seek(to: boundary)
  }

  private var editBoundaries: [Double] {
    var elapsed = 0.0
    var boundaries = [0.0]
    for clip in clips {
      elapsed += clip.duration
      boundaries.append(elapsed)
    }
    return boundaries
  }

  var timelineNavigationStep: Double {
    1.0 / (30 * max(1, timelineZoom))
  }

  func togglePlayback() {
    if player.timeControlStatus == .playing {
      player.pause()
      playback.isPlaying = false
    } else {
      if playhead >= duration - 0.05 { seek(to: 0) }
      player.play()
      playback.isPlaying = true
    }
  }

  @discardableResult
  func rebuildPlayback() async throws -> Bool {
    let generationID = UUID()
    playbackGenerationID = generationID
    let processedAudio: ProcessedAudio?
    if audio.normalizeLoudness {
      processedAudio = try await AudioProcessingService.process(
        clips: clips,
        settings: audio
      )
    } else {
      processedAudio = nil
    }

    do {
      guard playbackGenerationID == generationID else {
        if let processedAudio {
          try? FileManager.default.removeItem(at: processedAudio.url)
        }
        return false
      }
      let composition = try await CompositionBuilder.build(
        clips: clips,
        canvas: canvas,
        scalingMode: scalingMode,
        outputSize: canvas.previewSize,
        replacementAudioURL: processedAudio?.url
      )
      guard playbackGenerationID == generationID else {
        if let processedAudio {
          try? FileManager.default.removeItem(at: processedAudio.url)
        }
        return false
      }
      let item = AVPlayerItem(asset: composition.asset)
      item.videoComposition = composition.videoComposition
      item.audioMix = composition.audioMix
      let previousPreviewAudioURL = previewAudioURL
      previewAudioURL = processedAudio?.url
      resetPendingSeeks()
      player.replaceCurrentItem(with: item)
      seek(to: min(playhead, duration))
      if let previousPreviewAudioURL,
        previousPreviewAudioURL != previewAudioURL
      {
        try? FileManager.default.removeItem(at: previousPreviewAudioURL)
      }
      return true
    } catch {
      if let processedAudio {
        try? FileManager.default.removeItem(at: processedAudio.url)
      }
      throw error
    }
  }

  func setAudioNormalizationEnabled(_ enabled: Bool) {
    guard enabled != audio.normalizeLoudness else { return }
    resumePlaybackAfterAudioRebuild =
      resumePlaybackAfterAudioRebuild
      || player.timeControlStatus == .playing
    player.pause()
    playback.isPlaying = false
    recordUndoCheckpoint()
    audio = AudioSettings(normalizeLoudness: enabled)
    status = enabled
      ? "Готовим нормализованный звук для предпросмотра…"
      : "Возвращаем исходный звук…"
    Task {
      do {
        guard try await rebuildPlayback() else { return }
        if resumePlaybackAfterAudioRebuild {
          player.play()
          playback.isPlaying = true
        }
        resumePlaybackAfterAudioRebuild = false
        status = enabled
          ? "Автонормализация включена"
          : "Автонормализация выключена"
      } catch {
        resumePlaybackAfterAudioRebuild = false
        lastError = error.localizedDescription
        status = "Не удалось обновить звук предпросмотра"
      }
    }
  }

  func applyAutomaticColor() {
    colorAnalysisTask?.cancel()
    let generationID = UUID()
    colorAnalysisGenerationID = generationID
    let currentClips = clips
    guard !currentClips.isEmpty else { return }
    isAnalyzingColor = true
    status = "Анализируем цвет видео…"
    colorAnalysisTask = Task {
      do {
        let analyzed = try await AutoColorAnalyzer.analyze(clips: currentClips)
        try Task.checkCancellation()
        guard colorAnalysisGenerationID == generationID else { return }
        recordUndoCheckpoint()
        color = analyzed
        isAnalyzingColor = false
        status = "Автоцветокор применён"
      } catch is CancellationError {
        if colorAnalysisGenerationID == generationID {
          isAnalyzingColor = false
        }
      } catch {
        guard colorAnalysisGenerationID == generationID else { return }
        isAnalyzingColor = false
        lastError = error.localizedDescription
        status = "Не удалось проанализировать цвет"
      }
    }
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
      waveform = []
      waveformClips = []
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
      lastError = nil
      status = "Проект открыт"
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

  private func discardPreviewAudio() {
    guard let previewAudioURL else { return }
    try? FileManager.default.removeItem(at: previewAudioURL)
    self.previewAudioURL = nil
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
    synchronizeWaveformPreview()
    playbackRebuildTask?.cancel()
    playbackRebuildTask = Task {
      do {
        await hydrateSourceDurations()
        try Task.checkCancellation()
        try await rebuildPlayback()
        try Task.checkCancellation()
        generateWaveform()
        status = "Готово"
      } catch is CancellationError {
        return
      } catch {
        lastError = error.localizedDescription
        status = "Не удалось обновить монтаж"
      }
    }
  }

  private func clearPlaybackForEmptyProject() {
    playbackGenerationID = UUID()
    waveformGenerationID = UUID()
    player.pause()
    playback.isPlaying = false
    resetPendingSeeks()
    player.replaceCurrentItem(with: nil)
    discardPreviewAudio()
    waveform = []
    waveformClips = []
    playhead = 0
    timelineZoom = 1
    status = "Добавьте видео, чтобы начать"
  }

  private func synchronizeWaveformPreview() {
    guard !waveform.isEmpty, !waveformClips.isEmpty else { return }
    guard waveformClips != clips else { return }
    waveform = WaveformPresentation.remapped(
      waveform,
      from: waveformClips,
      to: clips
    )
    waveformClips = clips
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
