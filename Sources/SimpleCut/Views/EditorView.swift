@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject private var project: EditorProject
  @State private var importer: Importer?
  @State private var timeObserver: Any?
  @State private var playbackKeyMonitor: Any?
  @State private var showingExportSettings = false
  @State private var exportSettings = ExportSettings()
  @State private var pendingExportSettings: ExportSettings?
  @State private var exportTask: Task<Void, Never>?
  @State private var pendingProjectAction: PendingProjectAction?
  @State private var showingUnsavedChangesAlert = false

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
    VStack(spacing: 0) {
      toolbar
      Divider()
      HSplitView {
        VStack(spacing: 0) {
          ZStack {
            if project.clips.isEmpty {
              emptyState
            } else {
              PreviewCanvas()
                .padding(18)
            }
          }
          if !project.clips.isEmpty {
            transportBar
            Divider()
          }
          Divider()
          TimelineView()
            .frame(
              height: project.overlays.isEmpty ? 222 : 264
            )
        }
        InspectorView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .disabled(project.isBusy)
    .background(EditorTheme.canvas)
    .overlay {
      if project.isBusy {
        VStack(spacing: 10) {
          if let progress = project.exportProgress ?? project.transcriptionProgress {
            ProgressView(value: progress)
              .frame(width: 240)
          } else {
            ProgressView()
          }
          Text(project.status)
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
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.isEnabled, true)
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
      isPresented: Binding(
        get: { importer != nil },
        set: { if !$0 { importer = nil } }
      ),
      allowedContentTypes: allowedTypes,
      allowsMultipleSelection: false
    ) { result in
      handleImport(result)
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
      saveProject()
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutNew)) { _ in
      requestProjectAction(.new)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutOpen)) { _ in
      requestProjectAction(.open)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutSaveAs)) { _ in
      saveProject(saveAs: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutImport)) { _ in
      importer = .video
    }
    .onReceive(NotificationCenter.default.publisher(for: .simpleCutExport)) { _ in
      guard !project.clips.isEmpty, !project.isBusy else { return }
      showingExportSettings = true
    }
    .onOpenURL { url in
      requestProjectAction(.openURL(url))
    }
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
          importer = .video
        } label: {
          Label("Видео…", systemImage: "film")
        }
        Button {
          importer = .image
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
      .disabled(project.selectedClipIDs.isEmpty)
      .help("Удалить выбранный фрагмент (⌫)")
      .accessibilityLabel("Удалить выбранный фрагмент")
      Spacer()
      Text(project.name)
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
        Button("Сохранить проект…") { saveProject() }
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
          importer = .video
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

  private var transportBar: some View {
    HStack {
      Text(project.status)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
      Text(project.playhead.timestamp)
        .font(.caption.monospacedDigit())
      Button {
        project.togglePlayback()
      } label: {
        Image(
          systemName: project.player.timeControlStatus == .playing
            ? "pause.fill"
            : "play.fill"
        )
        .frame(width: 24)
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.space, modifiers: [])
      Text(project.duration.timestamp)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Spacer()
      Color.clear.frame(width: 100, height: 1)
    }
    .padding(.horizontal, 16)
    .frame(height: 38)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.45))
  }

  private var allowedTypes: [UTType] {
    switch importer {
    case .image: [.image]
    case .project: [.simpleCutProject, .json]
    default: [.movie, .mpeg4Movie, .quickTimeMovie]
    }
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      switch importer {
      case .image:
        project.addImage(url, securityScoped: true)
      case .project:
        try project.loadProject(from: url, securityScoped: true)
      default:
        project.importVideo(url, securityScoped: true)
      }
    } catch {
      project.lastError = error.localizedDescription
    }
    importer = nil
  }

  private func installTimeObserver() {
    guard timeObserver == nil else { return }
    timeObserver = project.player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
      queue: .main
    ) { time in
      Task { @MainActor in
        if project.player.timeControlStatus == .playing {
          project.playhead = min(time.seconds, project.duration)
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
      case 51, 117:
        guard !project.selectedClipIDs.isEmpty else { return event }
        project.deleteSelectedClips()
        return nil
      case 53:
        project.clearClipSelection()
        return nil
      default:
        return event
      }
    }
  }

  private func requestProjectAction(_ action: PendingProjectAction) {
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
      importer = .project
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
    panel.nameFieldStringValue = "\(project.name).simplecut"
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
    let trimmedName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseName = trimmedName.isEmpty ? "Видео" : trimmedName
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
}

extension UTType {
  static let simpleCutProject = UTType(
    exportedAs: "app.simplecut.project",
    conformingTo: .package
  )
}
