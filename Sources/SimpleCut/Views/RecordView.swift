import AppKit
import AVFoundation
import SwiftUI

struct RecordView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var project: EditorProject
  @StateObject private var recorder = RecordingService()
  @State private var isFinalizing = false
  @State private var showGrid = true
  @State private var teleprompterStartedAt: Date?
  @State private var devicesExpanded = false
  @State private var recordingExpanded = false
  @State private var teleprompterAppearanceExpanded = false
  @AppStorage("recording.countdownSeconds.v2") private var countdownSeconds = 0
  @AppStorage("teleprompter.enabled") private var teleprompterEnabled = false
  @AppStorage("teleprompter.text") private var teleprompterText = ""
  @AppStorage("teleprompter.fontSize.v2") private var teleprompterFontSize = 24.0
  @AppStorage("teleprompter.speed.v2") private var teleprompterSpeed = 90.0
  @AppStorage("teleprompter.backgroundOpacity")
  private var teleprompterBackgroundOpacity = 0.42

  var body: some View {
    VStack(spacing: 16) {
      statusBar
      HStack(alignment: .top, spacing: 20) {
        previewColumn
        settingsPanel
      }
    }
    .padding(20)
    .frame(minWidth: 980, minHeight: 680)
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      await recorder.startPreview()
      devicesExpanded = recorder.cameras.isEmpty || recorder.microphones.isEmpty
    }
    .onChange(of: recorder.selectedCameraID) {
      recorder.reconfigure()
    }
    .onChange(of: recorder.selectedMicrophoneID) {
      recorder.reconfigure()
    }
    .onChange(of: recorder.quality) {
      recorder.reconfigure()
    }
    .onChange(of: recorder.frameRate) {
      recorder.reconfigure()
    }
    .onChange(of: recorder.captureRotation) {
      recorder.applyVideoSettings()
    }
    .onChange(of: recorder.isMirrored) {
      recorder.applyVideoSettings()
    }
    .onChange(of: recorder.isRecording) {
      updateTeleprompterStart()
    }
    .onChange(of: recorder.isStartingRecording) {
      updateTeleprompterStart()
    }
    .onDisappear {
      if recorder.isRecording {
        recorder.stopRecording()
      } else if recorder.isStartingRecording {
        recorder.cancelRecordingStart()
      } else {
        recorder.stopPreview()
      }
    }
    .alert(
      "Ошибка записи",
      isPresented: Binding(
        get: { recorder.errorMessage != nil },
        set: { if !$0 { recorder.errorMessage = nil } }
      )
    ) {
      Button("OK") { recorder.errorMessage = nil }
    } message: {
      Text(recorder.errorMessage ?? "")
    }
  }

  private var statusBar: some View {
    HStack(spacing: 14) {
      Circle()
        .fill(statusColor)
        .frame(width: 9, height: 9)
        .shadow(color: statusColor.opacity(0.55), radius: 4)
      VStack(alignment: .leading, spacing: 1) {
        Text(statusTitle)
          .font(.headline)
        Text(statusDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .frame(minHeight: 34)
    .accessibilityElement(children: .combine)
  }

  private var previewColumn: some View {
    VStack(spacing: 10) {
      preview
      frameControls
    }
    .frame(maxWidth: 560)
  }

  private var preview: some View {
    ZStack {
      CameraPreview(
        session: recorder.session,
        device: recorder.selectedCamera,
        rotation: recorder.captureRotation,
        isMirrored: recorder.isMirrored,
        mode: recorder.previewMode
      )
      .background(.black)

      if showGrid {
        CompositionGrid()
          .padding(1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }

      if !recorder.isRecording, !recorder.isStartingRecording {
        VStack {
          HStack {
            Label(
              recorder.selectedCamera?.localizedName ?? "Камера не выбрана",
              systemImage: "video.fill"
            )
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.black.opacity(0.58), in: Capsule())
            .foregroundStyle(.white)
            Spacer()
          }
          Spacer()
        }
        .padding(12)
      }

      if teleprompterEnabled, !teleprompterText.trimmed.isEmpty {
        teleprompterOverlay
      }

      if let countdown = recorder.countdown {
        Text("\(countdown)")
          .font(.system(size: 112, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.65), radius: 10)
          .transition(.scale.combined(with: .opacity))
          .accessibilityLabel("Запись начнётся через \(countdown)")
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(.white.opacity(0.1))
    }
    .aspectRatio(project.canvas.aspectRatio, contentMode: .fit)
    .frame(maxWidth: 560, maxHeight: 560)
    .animation(.snappy, value: recorder.countdown)
  }

  private var teleprompterOverlay: some View {
    TeleprompterOverlay(
      text: teleprompterText,
      fontSize: teleprompterFontSize,
      wordsPerMinute: teleprompterSpeed,
      backgroundOpacity: teleprompterBackgroundOpacity,
      isRunning: recorder.isRecording,
      startedAt: teleprompterStartedAt
    )
    .accessibilityHidden(true)
  }

  private var frameControls: some View {
    HStack(spacing: 8) {
      Picker("Масштаб кадра", selection: $recorder.previewMode) {
        ForEach(CapturePreviewMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 190)

      Button {
        recorder.rotateClockwise()
      } label: {
        Image(systemName: "rotate.right")
          .frame(width: 18)
      }
      .accessibilityLabel("Повернуть на 90 градусов")
      .help("Повернуть на 90°")

      Button {
        recorder.toggleMirroring()
      } label: {
        Image(systemName: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right")
          .frame(width: 18)
      }
      .tint(recorder.isMirrored ? .accentColor : nil)
      .accessibilityLabel("Отразить по горизонтали")
      .help("Отразить по горизонтали")

      Toggle("Сетка", isOn: $showGrid)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
    .buttonStyle(.bordered)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(EditorTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    .disabled(configurationLocked)
  }

  private var settingsPanel: some View {
    VStack(spacing: 10) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          devicesCard
          recordingCard
          teleprompterCard
        }
        .padding(.trailing, 4)
      }
      .scrollIndicators(.visible)

      Divider()
      recordAction
    }
    .frame(width: 420)
  }

  private var devicesCard: some View {
    collapsibleSettingsCard(isExpanded: $devicesExpanded) {
      HStack(spacing: 10) {
        Label("Устройства", systemImage: "video.badge.checkmark")
          .font(.headline)
        Spacer()
        if !devicesExpanded {
          AudioLevelMeter(level: recorder.microphoneLevel)
            .frame(width: 64, height: 8)
          Image(
            systemName: recorder.cameras.isEmpty || recorder.microphones.isEmpty
              ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
          )
          .foregroundStyle(
            recorder.cameras.isEmpty || recorder.microphones.isEmpty
              ? Color.orange : Color.green
          )
        }
      }
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        devicePicker(
          title: "Камера",
          selection: $recorder.selectedCameraID,
          devices: recorder.cameras
        )
        devicePicker(
          title: "Микрофон",
          selection: $recorder.selectedMicrophoneID,
          devices: recorder.microphones
        )
        HStack(spacing: 8) {
          Text("Уровень")
            .font(.caption)
            .foregroundStyle(.secondary)
          AudioLevelMeter(level: recorder.microphoneLevel)
            .frame(height: 9)
          Button {
            recorder.refreshDevices()
            recorder.reconfigure()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .help("Обновить устройства")
        }
      }
    }
    .disabled(configurationLocked)
  }

  private var recordingCard: some View {
    collapsibleSettingsCard(isExpanded: $recordingExpanded) {
      HStack {
        Label("Запись", systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        if !recordingExpanded {
          Text(recordingSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          labeledPicker("Качество", selection: $recorder.quality) {
            ForEach(CaptureQuality.allCases) { quality in
              Text(quality.title).tag(quality)
            }
          }
          labeledPicker("Частота", selection: $recorder.frameRate) {
            ForEach(CaptureFrameRate.allCases) { rate in
              Text(rate.title).tag(rate)
            }
          }
          labeledPicker("Отсчёт", selection: $countdownSeconds) {
            Text("Без отсчёта").tag(0)
            Text("3 с").tag(3)
            Text("5 с").tag(5)
          }
        }
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Папка сохранения")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(recorder.outputDirectory?.lastPathComponent ?? "Медиатека SimpleCut")
              .lineLimit(1)
          }
          Spacer()
          Button("Выбрать…", action: chooseOutputDirectory)
        }
        Text(storageEstimate)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(configurationLocked)
  }

  private var teleprompterCard: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Label("Суфлёр", systemImage: "text.alignleft")
          .font(.headline)
        Spacer()
        Toggle("Суфлёр", isOn: $teleprompterEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .accessibilityLabel("Суфлёр")
      }
      .contentShape(Rectangle())

      if teleprompterEnabled {
        TextEditor(text: $teleprompterText)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(8)
          .frame(minHeight: 230)
          .background(EditorTheme.raised, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            if teleprompterText.isEmpty {
              Text("Вставьте сюда текст выступления…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .allowsHitTesting(false)
            }
          }
        HStack(spacing: 14) {
          compactSlider(
            title: "Размер",
            value: $teleprompterFontSize,
            range: 8...52,
            step: 2,
            valueLabel: "\(Int(teleprompterFontSize))"
          )
          compactSlider(
            title: "Скорость",
            value: $teleprompterSpeed,
            range: 30...240,
            step: 10,
            valueLabel: "\(Int(teleprompterSpeed)) слов/мин"
          )
        }
        DisclosureGroup("Настроить вид", isExpanded: $teleprompterAppearanceExpanded) {
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text("Затемнение под текстом")
              Spacer()
              Text("\(Int(teleprompterBackgroundOpacity * 100))%")
                .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Slider(
              value: $teleprompterBackgroundOpacity,
              in: 0.15...0.85
            )
          }
          .padding(.top, 8)
        }
        .font(.caption)
        Text(teleprompterStats)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 11)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(.white.opacity(0.045))
    }
  }

  private var recordAction: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: toggleRecording) {
        Label(recordButtonTitle, systemImage: recordButtonSystemImage)
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(
        recorder.isRecording
          ? .red
          : .accentColor
      )
      .keyboardShortcut("r", modifiers: .command)
      .disabled(recorder.cameras.isEmpty || isFinalizing)

      if isFinalizing {
        ProgressView("Добавляем запись…")
      } else {
        HStack {
          Text("⌘R")
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(EditorTheme.raised, in: RoundedRectangle(cornerRadius: 4))
          Text("После остановки клип появится в конце таймлайна.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.top, 2)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func settingsCard<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content()
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 11)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(.white.opacity(0.045))
    }
  }

  private func devicePicker(
    title: String,
    selection: Binding<String?>,
    devices: [AVCaptureDevice]
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker(title, selection: selection) {
        if devices.isEmpty {
          Text("Не найдено").tag(String?.none)
        }
        ForEach(devices, id: \.uniqueID) { device in
          Text(device.localizedName)
            .tag(Optional(device.uniqueID))
        }
      }
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(title)
    }
  }

  private func labeledPicker<Value: Hashable, Content: View>(
    _ title: String,
    selection: Binding<Value>,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker(title, selection: selection, content: content)
        .labelsHidden()
        .fixedSize()
    }
  }

  private func compactSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    valueLabel: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
          .foregroundStyle(.secondary)
        Spacer()
        Text(valueLabel)
          .monospacedDigit()
      }
      .font(.caption)
      Slider(value: value, in: range, step: step)
    }
  }

  private func collapsibleSettingsCard<LabelContent: View, Content: View>(
    isExpanded: Binding<Bool>,
    @ViewBuilder label: @escaping () -> LabelContent,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    DisclosureGroup(isExpanded: isExpanded) {
      content()
        .padding(.top, 10)
    } label: {
      label()
    }
    .padding(13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 11)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(.white.opacity(0.045))
    }
  }

  private func toggleRecording() {
    if recorder.isRecording {
      recorder.stopRecording()
    } else if recorder.isStartingRecording {
      recorder.cancelRecordingStart()
    } else if recorder.countdown != nil {
      recorder.cancelCountdown()
    } else {
      recorder.startRecording(countdown: countdownSeconds) { url in
        isFinalizing = true
        project.importVideo(url, copyToLibrary: false) { success in
          if success {
            Task {
              await recorder.stopPreviewAndWait()
              isFinalizing = false
              dismiss()
            }
          } else {
            isFinalizing = false
          }
        }
      }
    }
  }

  private func updateTeleprompterStart() {
    let active = recorder.isRecording
    if active, teleprompterStartedAt == nil {
      teleprompterStartedAt = Date()
    } else if !active {
      teleprompterStartedAt = nil
    }
  }

  private func chooseOutputDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Папка для записей"
    panel.prompt = "Выбрать"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK {
      recorder.outputDirectory = panel.url
    }
  }

  private var configurationLocked: Bool {
    recorder.isRecording || recorder.isStartingRecording || recorder.countdown != nil
  }

  private var statusTitle: String {
    if recorder.isRecording {
      return "Идёт запись · \(recorder.recordingDuration.timestamp)"
    }
    if recorder.isStartingRecording { return "Запуск записи…" }
    if recorder.countdown != nil { return "Приготовьтесь" }
    if recorder.cameras.isEmpty || recorder.microphones.isEmpty {
      return "Нужно выбрать устройства"
    }
    return "Готово к записи"
  }

  private var statusDetail: String {
    if recorder.isRecording {
      return "Клип записывается в выбранную папку"
    }
    if recorder.isStartingRecording {
      return "Сохраняем клип точно с момента запуска"
    }
    if recorder.cameras.isEmpty { return "Камера не найдена" }
    if recorder.microphones.isEmpty { return "Микрофон не найден" }
    return "Проверьте кадр и звук"
  }

  private var statusColor: Color {
    if recorder.isRecording { return .red }
    if recorder.isStartingRecording { return .orange }
    if recorder.countdown != nil { return .orange }
    if recorder.cameras.isEmpty || recorder.microphones.isEmpty { return .orange }
    return .green
  }

  private var storageEstimate: String {
    let root = recorder.outputDirectory ?? FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    guard let root,
      let values = try? root.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]
      ),
      let bytes = values.volumeAvailableCapacityForImportantUsage
    else {
      return "Свободное место будет проверено перед записью."
    }
    let megabytes = Double(bytes) / 1_048_576
    let rateMultiplier = Double(recorder.frameRate.rawValue) / 30
    let minutes = Int(
      megabytes / (recorder.quality.estimatedMegabytesPerMinute * rateMultiplier)
    )
    if minutes >= 120 {
      return "Доступно примерно \(minutes / 60) ч записи в выбранном качестве."
    }
    return "Доступно примерно \(max(0, minutes)) мин записи в выбранном качестве."
  }

  private var recordingSummary: String {
    let countdown = countdownSeconds == 0 ? "без отсчёта" : "\(countdownSeconds) с"
    return "\(recorder.quality.title) · \(recorder.frameRate.title) · \(countdown)"
  }

  private var teleprompterStats: String {
    let words = teleprompterText.split(whereSeparator: \.isWhitespace).count
    guard words > 0 else { return "0 слов" }
    let duration = Double(words) / max(30, teleprompterSpeed) * 60
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return "\(words) слов · ≈ \(minutes):\(String(format: "%02d", seconds))"
  }

  private var recordButtonTitle: String {
    if recorder.isRecording { return "Остановить запись" }
    if recorder.isStartingRecording { return "Остановить запись" }
    if recorder.countdown != nil { return "Отменить отсчёт" }
    return "Начать запись"
  }

  private var recordButtonSystemImage: String {
    if recorder.isRecording || recorder.isStartingRecording { return "stop.fill" }
    if recorder.countdown != nil { return "xmark" }
    return "record.circle"
  }
}

private struct CompositionGrid: View {
  var body: some View {
    GeometryReader { proxy in
      Path { path in
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
          let x = proxy.size.width * fraction
          path.move(to: CGPoint(x: x, y: 0))
          path.addLine(to: CGPoint(x: x, y: proxy.size.height))
          let y = proxy.size.height * fraction
          path.move(to: CGPoint(x: 0, y: y))
          path.addLine(to: CGPoint(x: proxy.size.width, y: y))
        }
      }
      .stroke(.white.opacity(0.32), lineWidth: 1)
    }
  }
}

private struct TeleprompterOverlay: View {
  let text: String
  let fontSize: Double
  let wordsPerMinute: Double
  let backgroundOpacity: Double
  let isRunning: Bool
  let startedAt: Date?

  var body: some View {
    VStack {
      SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
        let elapsed = startedAt.map {
          max(0, context.date.timeIntervalSince($0))
        } ?? 0
        let pointsPerSecond =
          fontSize * 1.35 * max(30, wordsPerMinute) / 420
        let offset = isRunning ? elapsed * pointsPerSecond : 0

        ScrollView(.vertical) {
          Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 3)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, offset + 80)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: -offset)
        }
        .scrollIndicators(isRunning ? .hidden : .visible)
        .scrollDisabled(isRunning)
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: 225,
        alignment: .top
      )
      .background(
        LinearGradient(
          colors: [
            .black.opacity(backgroundOpacity),
            .black.opacity(backgroundOpacity * 0.55),
            .clear,
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      Spacer()
    }
  }
}

private struct AudioLevelMeter: View {
  let level: Double

  var body: some View {
    GeometryReader { proxy in
      let clamped = min(1, max(0.075, level))
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.white.opacity(0.12))
        Capsule()
          .fill(
            LinearGradient(
              stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.72),
                .init(color: .yellow, location: 0.84),
                .init(color: .red, location: 1),
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: proxy.size.width * clamped)
      }
    }
    .accessibilityLabel("Уровень микрофона")
    .accessibilityValue("\(Int(level * 100)) процентов")
  }
}

private extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
