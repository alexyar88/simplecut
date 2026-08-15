@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject private var project: EditorProject
  @State private var importer: Importer?
  @State private var isImporterPresented = false
  @State private var timeObserver: Any?
  @State private var playbackKeyMonitor: Any?
  @State private var showingExportSettings = false
  @State private var exportSettings = ExportSettings()
  @State private var pendingExportSettings: ExportSettings?
  @State private var exportTask: Task<Void, Never>?
  @State private var pendingProjectAction: PendingProjectAction?
  @State private var showingUnsavedChangesAlert = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum Importer: Identifiable {
    case video
    case image
    case project
    var id: Self { self }
  }

  private enum PendingProjectAction {
    case new
    case open
    case openURL(URL)
  }

  var body: some View {
    GeometryReader { window in
      VStack(spacing: 0) {
        toolbar
        Divider()
        HSplitView {
          VStack(spacing: 0) {
            ZStack {
              PreviewCanvas(playback: project.playback)
                .padding(18)
                .opacity(project.clips.isEmpty ? 0 : 1)
                .scaleEffect(project.clips.isEmpty ? 0.985 : 1)
                .allowsHitTesting(!project.clips.isEmpty)
                .accessibilityHidden(project.clips.isEmpty)
              emptyState
                .opacity(project.clips.isEmpty ? 1 : 0)
                .scaleEffect(project.clips.isEmpty ? 1 : 0.985)
                .allowsHitTesting(project.clips.isEmpty)
                .accessibilityHidden(!project.clips.isEmpty)
            }
            EditorTransportBar(
              project: project,
              playback: project.playback
            )
              .opacity(project.clips.isEmpty ? 0 : 1)
              .allowsHitTesting(!project.clips.isEmpty)
              .accessibilityHidden(project.clips.isEmpty)
            Divider()
              .opacity(project.clips.isEmpty ? 0 : 1)
            Divider()
            TimelineView(playback: project.playback)
              .frame(height: timelineHeight)
          }
          InspectorView()
        }
      }
      .frame(width: window.size.width, height: window.size.height)
      .animation(
        reduceMotion ? nil : EditorTheme.softAnimation,
        value: project.clips.isEmpty
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .disabled(project.isBusy)
    .background(EditorTheme.canvas)
    .overlay {
      if project.isBusy {
        ZStack {
          Color.black.opacity(0.42)
            .ignoresSafeArea()
          VStack(spacing: 14) {
            if let progress = project.exportProgress ?? project.transcriptionProgress {
              ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 260)
              Text("\(Int(min(1, max(0, progress)) * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
              ProgressView()
                .controlSize(.large)
            }
            Text(project.status)
              .font(.headline)
              .multilineTextAlignment(.center)
            if exportTask != nil {
              Button("Отменить экспорт") {
                exportTask?.cancel()
              }
            } else if project.isTranscribing {
              Button("Отменить создание субтитров") {
                project.cancelTranscription()
              }
            }
          }
          .padding(24)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
          .overlay {
            RoundedRectangle(cornerRadius: 16)
              .stroke(.white.opacity(0.12), lineWidth: 1)
          }
          .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        }
        .environment(\.isEnabled, true)
        .transition(.opacity)
      }
    }
    .alert(
      "SimpleCut",
      isPresented: Binding(
        get: { project.lastError != nil },
        set: { if !$0 { project.lastError = nil } }
      )
    ) {
      Button("OK") { project.lastError = nil }
    } message: {
      Text(project.lastError ?? "")
    }
    .alert(
      "Есть несохранённые изменения",
      isPresented: $showingUnsavedChangesAlert
    ) {
      Button("Сохранить") {
        saveProject { didSave in
          if didSave {
            DispatchQueue.main.async {
              performPendingProjectAction()
            }
          } else {
            pendingProjectAction = nil
          }
        }
      }
      Button("Не сохранять", role: .destructive) {
        performPendingProjectAction()
      }
      Button("Отмена", role: .cancel) {
        pendingProjectAction = nil
      }
    } message: {
      Text("Сохраните текущий проект перед продолжением, чтобы не потерять изменения.")
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: allowedTypes,
      allowsMultipleSelection: false
    ) { result in
      let completedImporter = importer
      importer = nil
      handleImport(result, as: completedImporter)
    }
    .sheet(
      isPresented: $showingExportSettings,
      onDismiss: {
        guard let settings = pendingExportSettings else { return }
        pendingExportSettings = nil
        presentExportPanel(settings: settings)
      }
    ) {
      ExportSettingsView(
        settings: $exportSettings,
        canvas: project.canvas,
        duration: project.duration,
        projectName: project.name,
        onExport: {
          pendingExportSettings = exportSettings
          showingExportSettings = false
        },
        onCancel: {
          showingExportSettings = false
        }
      )
    }
    .onAppear {
      installTimeObserver()
      installPlaybackKeyMonitor()
      if !project.clips.isEmpty, project.player.currentItem == nil {
        Task {
          do {
            try await project.preparePlayback()
          } catch {
            project.lastError = error.localizedDescription
          }
        }
      }
    }
    .onDisappear {
      if let timeObserver {
        project.player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
      }
      if let playbackKeyMonitor {
        NSEvent.removeMonitor(playbackKeyMonitor)
        self.playbackKeyMonitor = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutSave)) { _ in
      guard !project.isBusy else { return }
      saveProject()
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutNew)) { _ in
      guard !project.isBusy else { return }
      requestProjectAction(.new)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutOpen)) { _ in
      guard !project.isBusy else { return }
      requestProjectAction(.open)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutSaveAs)) { _ in
      guard !project.isBusy else { return }
      saveProject(saveAs: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutImport)) { _ in
      guard !project.isBusy else { return }
      presentImporter(.video)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutExport)) { _ in
      guard !project.clips.isEmpty, !project.isBusy else { return }
      showingExportSettings = true
    }
    .onOpenURL { url in
      guard !project.isBusy else { return }
      requestProjectAction(.openURL(url))
    }
  }

  private var timelineHeight: CGFloat {
    (project.clips.isEmpty ? 222 : 252)
      + CGFloat(OverlayKind.timelineKinds(for: project.overlays).count) * 42
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        openWindow(id: "recording")
      } label: {
        Label("Запись", systemImage: "record.circle")
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .accessibilityIdentifier("record-button")

      Menu {
        Button {
          presentImporter(.video)
        } label: {
          Label("Видео…", systemImage: "film")
        }
        Button {
          presentImporter(.image)
        } label: {
          Label("Изображение…", systemImage: "photo")
        }
        Divider()
        Button {
          project.addText()
        } label: {
          Label("Текст", systemImage: "textformat")
        }
        Button {
          project.generateCaptions()
        } label: {
          Label("Автосубтитры", systemImage: "captions.bubble")
        }
        .disabled(project.clips.isEmpty || project.isTranscribing)
      } label: {
        Label("Добавить", systemImage: "plus")
      }

      Divider().frame(height: 22)
      Button {
        project.splitAtPlayhead()
      } label: {
        Image(systemName: "scissors")
      }
      .buttonStyle(EditorIconButtonStyle())
      .disabled(!project.canSplitAtPlayhead)
      .help("Разрезать по позиции курсора (⌘B)")
      .accessibilityLabel("Разрезать по позиции курсора")
      Button {
        project.joinSelectedClips()
      } label: {
        Label("Объединить", systemImage: "link")
      }
      .disabled(!project.canJoinSelectedClips)
      .help("Объединить выбранные соседние фрагменты")
      .accessibilityLabel("Объединить выбранные фрагменты")
      Button {
        project.deleteSelectedClips()
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(EditorIconButtonStyle())
      .disabled(project.selectedClipIDs.isEmpty)
      .help("Удалить выбранный фрагмент (⌫)")
      .accessibilityLabel("Удалить выбранный фрагмент")
      Spacer()
      Text(project.displayName)
        .font(.headline)
        .lineLimit(1)
      if project.isDirty {
        Circle()
          .fill(.orange)
          .frame(width: 7, height: 7)
          .help("Есть несохранённые изменения")
      }

      Menu {
        Button("Новый проект") { requestProjectAction(.new) }
        Divider()
        Button("Открыть проект…") { requestProjectAction(.open) }
        Button(
          project.currentProjectURL == nil
            ? "Сохранить проект…"
            : "Сохранить проект"
        ) {
          saveProject()
        }
        Button("Сохранить как…") { saveProject(saveAs: true) }
      } label: {
        Label("Проект", systemImage: "ellipsis.circle")
      }
      .help("Проект")
      .accessibilityLabel("Проект")

      Button("Экспорт") { showingExportSettings = true }
        .buttonStyle(.borderedProminent)
        .disabled(project.clips.isEmpty || project.isBusy)
        .accessibilityIdentifier("export-button")
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
    .background(EditorTheme.raised)
    .overlay(alignment: .bottom) {
      Rectangle().fill(EditorTheme.subtleSeparator).frame(height: 1)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "film.stack")
        .font(.system(size: 46, weight: .light))
        .foregroundStyle(.secondary)
      VStack(spacing: 6) {
        Text("Начните с видео")
          .font(.title2.bold())
        Text("Запишите новое или импортируйте готовый файл")
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        Button {
          presentImporter(.video)
        } label: {
          Label("Импортировать", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        Button {
          openWindow(id: "recording")
        } label: {
          Label("Записать", systemImage: "record.circle")
        }
      }
    }
    .padding(32)
  }

  private var allowedTypes: [UTType] {
    switch importer {
    case .image: [.image]
    case .project:
      // `.package` keeps projects selectable if Launch Services has not yet
      // refreshed the app's exported UTType after an update.
      [.simpleCutProject, .package, .json]
    default: [.movie, .mpeg4Movie, .quickTimeMovie]
    }
  }

  private func presentImporter(_ kind: Importer) {
    guard !project.isBusy else { return }
    importer = kind
    isImporterPresented = true
  }

  private func handleImport(
    _ result: Result<[URL], Error>,
    as completedImporter: Importer?
  ) {
    do {
      guard let url = try result.get().first else { return }
      switch completedImporter {
      case .image:
        project.addImage(url, securityScoped: true)
      case .project:
        guard ProjectPackageService.canOpen(url) else {
          throw ProjectPackageError.unsupportedFileType
        }
        try project.loadProject(from: url, securityScoped: true)
      case .video:
        project.importVideo(url, securityScoped: true)
      case nil:
        return
      }
    } catch {
      if (error as NSError).code == NSUserCancelledError { return }
      project.lastError = error.localizedDescription
    }
  }

  private func installTimeObserver() {
    guard timeObserver == nil else { return }
    timeObserver = project.player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
      queue: .main
    ) { time in
      Task { @MainActor in
        let wasPlaying = project.playback.isPlaying
        let isPlaying = project.player.timeControlStatus == .playing
        project.playback.isPlaying = isPlaying
        if isPlaying || wasPlaying {
          let playhead = min(time.seconds, project.duration)
          project.playback.playhead = playhead
          project.playback.anchoredPlayhead = playhead
        }
      }
    }
  }

  private func installPlaybackKeyMonitor() {
    guard playbackKeyMonitor == nil else { return }
    playbackKeyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { event in
      let editingText = event.window?.firstResponder is NSTextView
      if event.keyCode == 0,
        !event.modifierFlags.intersection([.command, .control]).isEmpty,
        event.window?.title != "Запись",
        event.window?.sheetParent == nil,
        event.window?.attachedSheet == nil,
        !editingText
      {
        project.selectAllClips()
        return nil
      }
      guard
        event.modifierFlags
          .intersection([.command, .control, .option]).isEmpty,
        event.window?.title != "Запись",
        event.window?.sheetParent == nil,
        event.window?.attachedSheet == nil,
        !editingText
      else {
        return event
      }

      switch event.keyCode {
      case 49 where !event.isARepeat:
        project.togglePlayback()
        return nil
      case 123:
        let step =
          event.modifierFlags.contains(.shift)
          ? 1 / project.timelineZoom
          : project.timelineNavigationStep
        project.seek(by: -step)
        return nil
      case 124:
        let step =
          event.modifierFlags.contains(.shift)
          ? 1 / project.timelineZoom
          : project.timelineNavigationStep
        project.seek(by: step)
        return nil
      case 126:
        project.seekToPreviousEdit()
        return nil
      case 125:
        project.seekToNextEdit()
        return nil
      case 115:
        project.seek(to: 0)
        return nil
      case 119:
        project.seek(to: project.duration)
        return nil
      case 51, 117:
        if project.selectedOverlayID != nil {
          project.deleteSelectedOverlay()
          return nil
        }
        guard !project.selectedClipIDs.isEmpty else { return event }
        project.deleteSelectedClips()
        return nil
      case 53:
        project.clearClipSelection()
        project.selectedOverlayID = nil
        return nil
      default:
        return event
      }
    }
  }

  private func requestProjectAction(_ action: PendingProjectAction) {
    guard !project.isBusy else { return }
    pendingProjectAction = action
    if project.isDirty {
      showingUnsavedChangesAlert = true
    } else {
      performPendingProjectAction()
    }
  }

  private func performPendingProjectAction() {
    guard let action = pendingProjectAction else { return }
    pendingProjectAction = nil
    switch action {
    case .new:
      project.reset()
    case .open:
      presentImporter(.project)
    case .openURL(let url):
      do {
        try project.loadProject(from: url, securityScoped: true)
      } catch {
        project.lastError = error.localizedDescription
      }
    }
  }

  private func saveProject(
    saveAs: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    if !saveAs, let url = project.currentProjectURL {
      do {
        try project.saveProject(to: url)
        completion?(true)
      } catch {
        project.lastError = error.localizedDescription
        completion?(false)
      }
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.simpleCutProject]
    let baseName = safeProjectName(fallback: "Без названия")
    panel.nameFieldStringValue = "\(baseName).simplecut"
    panel.isExtensionHidden = false
    panel.canCreateDirectories = true
    DispatchQueue.main.async {
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          completion?(false)
          return
        }
        do {
          try project.saveProject(to: url)
          completion?(true)
        } catch {
          project.lastError = error.localizedDescription
          completion?(false)
        }
      }
    }
  }

  private func presentExportPanel(settings: ExportSettings) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    let baseName = safeProjectName(fallback: "Видео")
    panel.nameFieldStringValue = "\(baseName).mp4"
    panel.isExtensionHidden = false
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      exportVideo(settings: settings, to: url)
    }
  }

  private func exportVideo(settings: ExportSettings, to url: URL) {
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCutExport-\(UUID().uuidString).mp4")
    project.isBusy = true
    project.exportProgress = 0
    project.status = "Экспорт видео…"
    exportTask = Task {
      defer {
        try? FileManager.default.removeItem(at: staging)
        project.isBusy = false
        project.exportProgress = nil
        exportTask = nil
      }
      do {
        try await ExportService.export(
          clips: project.clips,
          overlays: project.overlays,
          canvas: project.canvas,
          scalingMode: project.scalingMode,
          audio: project.audio,
          color: project.color,
          settings: settings,
          progress: { project.exportProgress = $0 },
          to: staging
        )
        if FileManager.default.fileExists(atPath: url.path) {
          _ = try FileManager.default.replaceItemAt(
            url,
            withItemAt: staging
          )
        } else {
          try FileManager.default.moveItem(at: staging, to: url)
        }
        project.status = "Экспорт завершён"
      } catch is CancellationError {
        project.status = "Экспорт отменён"
      } catch {
        project.lastError = error.localizedDescription
        project.status = "Ошибка экспорта"
      }
    }
  }

  private func safeProjectName(fallback: String) -> String {
    let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}

private struct EditorTransportBar: View {
  @ObservedObject var project: EditorProject
  @ObservedObject var playback: PlaybackState

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 7) {
        Circle()
          .fill(project.isBusy ? EditorTheme.selection : Color.green)
          .frame(width: 6, height: 6)
        Text(project.status)
          .lineLimit(1)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: 260, alignment: .leading)
      Spacer()
      Text(playback.playhead.timestamp)
        .font(.caption.monospacedDigit())
        .frame(minWidth: 62, alignment: .trailing)
      Button {
        project.seekToPreviousEdit()
      } label: {
        Image(systemName: "backward.end.fill")
      }
      .buttonStyle(EditorIconButtonStyle())
      .help("К предыдущему стыку (↑)")
      Button {
        project.seek(by: -project.timelineNavigationStep)
      } label: {
        Image(systemName: "backward.frame.fill")
      }
      .buttonStyle(EditorIconButtonStyle())
      .help("На один кадр назад (←)")
      Button {
        project.togglePlayback()
      } label: {
        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 32, height: 26)
          .background(EditorTheme.accent, in: Capsule())
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.space, modifiers: [])
      .help("Воспроизвести или поставить на паузу (Пробел)")
      Button {
        project.seek(by: project.timelineNavigationStep)
      } label: {
        Image(systemName: "forward.frame.fill")
      }
      .buttonStyle(EditorIconButtonStyle())
      .help("На один кадр вперёд (→)")
      Button {
        project.seekToNextEdit()
      } label: {
        Image(systemName: "forward.end.fill")
      }
      .buttonStyle(EditorIconButtonStyle())
      .help("К следующему стыку (↓)")
      Text(project.duration.timestamp)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 62, alignment: .leading)
      Spacer()
      Color.clear.frame(width: 260, height: 1)
    }
    .padding(.horizontal, 16)
    .frame(height: 38)
    .background(EditorTheme.raised.opacity(0.76))
    .overlay(alignment: .top) {
      Rectangle().fill(EditorTheme.subtleSeparator).frame(height: 1)
    }
  }
}

extension UTType {
  static let simpleCutProject = UTType(
    exportedAs: "app.simplecut.project",
    conformingTo: .package
  )
}
