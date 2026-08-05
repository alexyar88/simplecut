import SwiftUI

struct InspectorView: View {
  @EnvironmentObject private var project: EditorProject

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section("Проект") {
          TextField(
            "Название",
            text: Binding(
              get: { project.name },
              set: {
                guard $0 != project.name else { return }
                project.recordUndoCheckpoint()
                project.name = $0
              }
            )
          )
          Picker(
            "Формат",
            selection: Binding(
              get: { project.canvas },
              set: {
                guard $0 != project.canvas else { return }
                project.recordUndoCheckpoint()
                project.canvas = $0
                Task {
                  do {
                    try await project.rebuildPlayback()
                  } catch {
                    project.lastError = error.localizedDescription
                  }
                }
              }
            )
          ) {
            ForEach(CanvasPreset.allCases) { preset in
              Text(preset.title).tag(preset)
            }
          }
          Picker(
            "Видео в кадре",
            selection: Binding(
              get: { project.scalingMode },
              set: {
                guard $0 != project.scalingMode else { return }
                project.recordUndoCheckpoint()
                project.scalingMode = $0
                Task {
                  do {
                    try await project.rebuildPlayback()
                  } catch {
                    project.lastError = error.localizedDescription
                  }
                }
              }
            )
          ) {
            ForEach(VideoScalingMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
        }

        if let index = project.selectedOverlayIndex {
          overlaySection(index: index)
            .id("selected-overlay")
        }

        if let index = project.selectedClipIndex {
          clipSection(index: index)
            .id("selected-clip")
        } else if project.selectedClipIDs.count > 1 {
          Section("Выбранные фрагменты") {
            LabeledContent(
              "Количество",
              value: "\(project.selectedClipIDs.count)"
            )
            Text("Удаление и перемещение применяются ко всему выделению.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if !project.clips.isEmpty {
          Section("Звук всего проекта") {
            Toggle(
              "Автонормализация звука",
              isOn: Binding(
                get: { project.audio.normalizeLoudness },
                set: {
                  guard $0 != project.audio.normalizeLoudness else { return }
                  project.recordUndoCheckpoint()
                  project.audio = AudioSettings(normalizeLoudness: $0)
                }
              )
            )
            Text("Выравнивает громкость и защищает пики автоматически.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Section("Цвет всего проекта") {
            colorSlider(
              "Яркость",
              value: $project.color.brightness,
              range: -0.25...0.25
            )
            colorSlider(
              "Контраст",
              value: $project.color.contrast,
              range: 0.5...1.5
            )
            colorSlider(
              "Насыщенность",
              value: $project.color.saturation,
              range: 0...2
            )
            colorSlider(
              "Теплота",
              value: $project.color.warmth,
              range: -1...1
            )
            HStack {
              Button("Авто") {
                project.recordUndoCheckpoint()
                project.color = .automatic
              }
              Button("Сбросить") {
                project.recordUndoCheckpoint()
                project.color = .neutral
              }
              .disabled(project.color.isNeutral)
            }
          }

          Section("Автосубтитры") {
            Picker(
              "Язык",
              selection: $project.transcriptionLanguage
            ) {
              ForEach(TranscriptionLanguage.allCases) { language in
                Text(language.title).tag(language)
              }
            }
            Picker("Модель речи", selection: $project.transcriptionModel) {
              ForEach(TranscriptionModel.allCases) { model in
                Text(model.title).tag(model)
              }
            }
            Text(project.transcriptionModel.downloadHint)
              .font(.caption)
              .foregroundStyle(.secondary)
            if project.isTranscribing {
              Button("Отменить создание", role: .cancel) {
                project.cancelTranscription()
              }
            } else {
              Button {
                project.generateCaptions()
              } label: {
                Label("Создать субтитры", systemImage: "captions.bubble")
              }
            }
          }
        }

        if project.selectedOverlayIndex == nil {
          Section("Подсказка") {
            Text("Добавьте текст или изображение и перетащите его прямо в окне просмотра.")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(EditorTheme.panel)
      .onChange(of: project.selectedOverlayID) {
        guard project.selectedOverlayID != nil else { return }
        withAnimation {
          proxy.scrollTo("selected-overlay", anchor: .top)
        }
      }
      .onChange(of: project.selectedClipID) {
        guard project.selectedClipIndex != nil else { return }
        withAnimation {
          proxy.scrollTo("selected-clip", anchor: .top)
        }
      }
    }
    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
    .background(EditorTheme.panel)
  }

  @ViewBuilder
  private func clipSection(index: Int) -> some View {
    let clip = project.clips[index]
    let timelineStart = project.clips.prefix(index).reduce(0) {
      $0 + $1.duration
    }
    Section("Фрагмент \(index + 1)") {
      LabeledContent("На таймлайне", value: timelineStart.timestamp)
      LabeledContent("Длительность", value: clip.duration.timestamp)
      LabeledContent("Начало в исходнике", value: clip.sourceStart.timestamp)
      LabeledContent("Файл") {
        Text(clip.sourceURL.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(clip.sourceURL.path)
      }
      Text("Потяните за края выбранного фрагмента на таймлайне, чтобы обрезать его.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func overlaySection(index: Int) -> some View {
    Section(layerTitle(project.overlays[index].kind)) {
      if project.overlays[index].kind.isTextual {
        TextField(
          "Текст",
          text: Binding(
            get: { project.overlays[index].text ?? "" },
            set: {
              guard $0 != project.overlays[index].text else { return }
              project.recordUndoCheckpoint()
              project.overlays[index].text = $0
            }
          ),
          axis: .vertical
        )
        valueSlider(
          "Размер шрифта",
          valueText: "\(Int(project.overlays[index].fontSize.rounded())) pt",
          value: $project.overlays[index].fontSize,
          range: 20...160
        )
      }
      LabeledContent("Начало") {
        EditableTimeField(
          value: project.overlays[index].startTime,
          range: 0...max(0, project.duration - 0.1),
          accessibilityLabel: "Начало слоя"
        ) { value in
          project.recordUndoCheckpoint()
          project.setOverlayStart(id: project.overlays[index].id, to: value)
        }
      }
      LabeledContent("Длительность") {
        EditableTimeField(
          value: project.overlays[index].duration,
          range:
            0.1...max(
              0.1,
              project.duration - project.overlays[index].startTime
            ),
          accessibilityLabel: "Длительность слоя"
        ) { value in
          project.recordUndoCheckpoint()
          project.setOverlayDuration(
            id: project.overlays[index].id,
            to: value
          )
        }
      }
      Slider(
        value: $project.overlays[index].duration,
        in:
          0.1...max(
            0.1,
            project.duration - project.overlays[index].startTime
          ),
        onEditingChanged: checkpointAtStart
      )
      .accessibilityLabel("Длительность слоя")
      .accessibilityValue(project.overlays[index].duration.timestamp)
      valueSlider(
        "Ширина",
        valueText: "\(Int((project.overlays[index].normalizedWidth * 100).rounded()))%",
        value: $project.overlays[index].normalizedWidth,
        range: 0.1...1
      )
      valueSlider(
        "Прозрачность",
        valueText: "\(Int((project.overlays[index].opacity * 100).rounded()))%",
        value: $project.overlays[index].opacity,
        range: 0...1
      )
      valueSlider(
        "Поворот",
        valueText: "\(Int(project.overlays[index].rotation.rounded()))°",
        value: $project.overlays[index].rotation,
        range: -180...180
      )
      Button("Удалить слой", role: .destructive) {
        project.recordUndoCheckpoint()
        project.overlays.remove(at: index)
        project.selectedOverlayID = nil
      }
    }
  }

  private func checkpointAtStart(_ isEditing: Bool) {
    if isEditing {
      project.recordUndoCheckpoint()
    }
  }

  private func valueSlider(
    _ title: String,
    valueText: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent(title, value: valueText)
      Slider(
        value: value,
        in: range,
        onEditingChanged: checkpointAtStart
      )
      .accessibilityLabel(title)
      .accessibilityValue(valueText)
    }
  }

  private func colorSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    valueSlider(
      title,
      valueText: String(format: "%.2f", value.wrappedValue),
      value: value,
      range: range
    )
  }

  private func layerTitle(_ kind: OverlayKind) -> String {
    switch kind {
    case .text: "Текст"
    case .caption: "Субтитры"
    case .image: "Изображение"
    }
  }
}

private struct EditableTimeField: View {
  let value: Double
  let range: ClosedRange<Double>
  let accessibilityLabel: String
  let onCommit: (Double) -> Void
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField("0.0", text: $draft)
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .frame(width: 74)
      .focused($isFocused)
      .onAppear { synchronizeDraft() }
      .onChange(of: value) {
        if !isFocused { synchronizeDraft() }
      }
      .onChange(of: isFocused) {
        if !isFocused { commit() }
      }
      .onSubmit {
        commit()
        isFocused = false
      }
      .accessibilityLabel(accessibilityLabel)
      .help("Введите время в секундах")
  }

  private func synchronizeDraft() {
    draft = String(format: "%.1f", value)
  }

  private func commit() {
    let normalized = draft.replacingOccurrences(of: ",", with: ".")
    guard let parsed = Double(normalized) else {
      synchronizeDraft()
      return
    }
    let clamped = min(max(parsed, range.lowerBound), range.upperBound)
    if abs(clamped - value) > 0.0001 {
      onCommit(clamped)
    }
    draft = String(format: "%.1f", clamped)
  }
}
