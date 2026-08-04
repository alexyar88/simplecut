@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
  @EnvironmentObject private var project: EditorProject
  @State private var importer: Importer?
  @State private var timeObserver: Any?
  @State private var showingRecorder = false
  @State private var showingExportSettings = false
  @State private var exportSettings = ExportSettings()
  @State private var exportTask: Task<Void, Never>?

  private enum Importer: Identifiable {
    case video
    case image
    case project
    var id: Self { self }
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
            .frame(height: project.clips.isEmpty ? 150 : 190)
        }
        InspectorView()
      }
    }
    .background(Color(nsColor: .underPageBackgroundColor))
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
          }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
    .sheet(isPresented: $showingRecorder) {
      RecordView()
        .environmentObject(project)
    }
    .sheet(isPresented: $showingExportSettings) {
      ExportSettingsView(
        settings: $exportSettings,
        onExport: {
          showingExportSettings = false
          exportVideo(settings: exportSettings)
        },
        onCancel: {
          showingExportSettings = false
        }
      )
    }
    .onAppear {
      installTimeObserver()
    }
    .onDisappear {
      if let timeObserver {
        project.player.removeTimeObserver(timeObserver)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        showingRecorder = true
      } label: {
        Label("Запись", systemImage: "record.circle")
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)

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
      .disabled(project.clips.isEmpty)
      .help("Разрезать по позиции курсора (⌘B)")
      Button {
        project.deleteSelectedClip()
      } label: {
        Image(systemName: "trash")
      }
      .disabled(project.selectedClipID == nil)
      .help("Удалить выбранный фрагмент")
      Spacer()

      Menu {
        Button("Открыть проект…") { importer = .project }
        Button("Сохранить проект…") { saveProject() }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .help("Проект")

      Button("Экспорт") { showingExportSettings = true }
        .buttonStyle(.borderedProminent)
        .disabled(project.clips.isEmpty || project.isBusy)
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
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
          showingRecorder = true
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
        project.addImage(url)
      case .project:
        try project.loadProject(from: url)
      default:
        project.importVideo(url, securityScoped: true)
      }
    } catch {
      project.lastError = error.localizedDescription
    }
    importer = nil
  }

  private func installTimeObserver() {
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

  private func saveProject() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.simpleCutProject]
    panel.nameFieldStringValue = "\(project.name).simplecut"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try project.saveProject(to: url)
    } catch {
      project.lastError = error.localizedDescription
    }
  }

  private func exportVideo(settings: ExportSettings) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.nameFieldStringValue = "\(project.name).mp4"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let staging = url.deletingLastPathComponent()
      .appendingPathComponent(".SimpleCutExport-\(UUID().uuidString).mp4")
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
