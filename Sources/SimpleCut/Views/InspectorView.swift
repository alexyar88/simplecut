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

        if !project.clips.isEmpty {
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
              HStack {
                Button("Создать субтитры") {
                  project.generateCaptions()
                }
                Button("Удалить субтитры", role: .destructive) {
                  project.deleteAllCaptions()
                }
                .tint(.red)
                .disabled(
                  !project.overlays.contains(where: { $0.kind == .caption })
                )
              }
              .controlSize(.small)
              .font(.caption)
            }
          }

          if project.overlays.contains(where: { $0.kind == .caption }) {
            captionSettingsSection
            captionEditorSection
          }

          if let index = project.selectedOverlayIndex,
            project.overlays[index].kind != .caption
          {
            overlaySection(index: index)
              .id("selected-overlay")
          }

          Section("Звук всего проекта") {
            Toggle(
              "Автонормализация звука",
              isOn: Binding(
                get: { project.audio.normalizeLoudness },
                set: {
                  project.setAudioNormalizationEnabled($0)
                }
              )
            )
            Text(
              "Повышает среднюю громкость, мягко сжимает динамику "
                + "и защищает пики."
            )
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

        }

        if project.overlays.isEmpty {
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
        guard let index = project.selectedOverlayIndex else { return }
        withAnimation {
          if project.overlays[index].kind == .caption {
            proxy.scrollTo(
              "caption-\(project.overlays[index].id)",
              anchor: .center
            )
          } else {
            proxy.scrollTo("selected-overlay", anchor: .top)
          }
        }
      }
    }
    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
    .background(EditorTheme.panel)
  }

  private var captionEditorSection: some View {
    Section("Текст субтитров") {
      ForEach(
        project.overlays.filter { $0.kind == .caption }.map(\.id),
        id: \.self
      ) { id in
        if let index = project.overlays.firstIndex(where: { $0.id == id }) {
          captionRow(index: index)
        }
      }
    }
  }

  private var captionSettingsSection: some View {
    Section("Оформление субтитров") {
      Menu {
        ForEach(CaptionStylePreset.allCases) { preset in
          Button(preset.title) {
            project.applyCaptionPreset(preset)
          }
        }
        if project.hasSavedCaptionStyle {
          Divider()
          Button("Мой стиль") {
            project.applySavedCaptionStyle()
          }
        }
      } label: {
        HStack {
          Text("Быстрый стиль")
          Spacer()
          Image(systemName: "chevron.down")
            .font(.caption.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          Color.primary.opacity(0.09),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      Picker(
        "Шрифт",
        selection: captionBinding(
          \.fontName,
          fallback: "Helvetica Neue",
          recordsCheckpoint: true
        )
      ) {
        ForEach(
          ["Helvetica Neue", "Arial", "Avenir Next", "Georgia", "Menlo"],
          id: \.self
        ) { family in
          Text(family).tag(family)
        }
      }
      Picker(
        "Начертание",
        selection: captionBinding(
          \.fontWeight,
          fallback: .semibold,
          recordsCheckpoint: true
        )
      ) {
        ForEach(CaptionFontWeight.allCases) { weight in
          Text(weight.title).tag(weight)
        }
      }
      valueSlider(
        "Размер шрифта",
        valueText:
          "\(Int(captionBinding(\.fontSize, fallback: 58).wrappedValue.rounded())) pt",
        value: captionBinding(\.fontSize, fallback: 58),
        range: 20...160
      )
      ColorPicker(
        "Цвет текста",
        selection: captionColorBinding(\.foregroundHex),
        supportsOpacity: true
      )
      ColorPicker(
        "Цвет подложки",
        selection: captionColorBinding(\.backgroundHex),
        supportsOpacity: true
      )
      ColorPicker(
        "Цвет обводки",
        selection: captionColorBinding(\.strokeHex),
        supportsOpacity: true
      )
      valueSlider(
        "Толщина обводки",
        valueText:
          "\(Int(captionBinding(\.strokeWidth, fallback: 0).wrappedValue.rounded())) pt",
        value: captionBinding(\.strokeWidth, fallback: 0),
        range: 0...12
      )
      valueSlider(
        "Отступы",
        valueText:
          "\(Int(captionBinding(\.textPadding, fallback: 12).wrappedValue.rounded())) pt",
        value: captionBinding(\.textPadding, fallback: 12),
        range: 0...40
      )
      valueSlider(
        "Скругление",
        valueText:
          "\(Int(captionBinding(\.cornerRadius, fallback: 8).wrappedValue.rounded())) pt",
        value: captionBinding(\.cornerRadius, fallback: 8),
        range: 0...32
      )
      valueSlider(
        "Ширина",
        valueText:
          "\(Int((captionBinding(\.normalizedWidth, fallback: 0.82).wrappedValue * 100).rounded()))%",
        value: captionBinding(\.normalizedWidth, fallback: 0.82),
        range: 0.25...1
      )
      HStack {
        Button("Сохранить стиль") {
          project.saveCurrentCaptionStyle()
        }
        .buttonStyle(.bordered)
        Button("Удалить стиль", role: .destructive) {
          project.deleteSavedCaptionStyle()
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(!project.canDeleteCurrentCaptionStyle)
      }
    }
  }

  private func captionRow(index: Int) -> some View {
    let item = project.overlays[index]
    let isSelected = project.selectedOverlayID == item.id
    return VStack(alignment: .leading, spacing: 2) {
      Text(item.startTime.timestamp)
      .font(.caption2.monospacedDigit())
      .foregroundStyle(isSelected ? Color.accentColor : .secondary)
      .lineLimit(1)
      TextField(
        "Текст",
        text: Binding(
          get: {
            project.overlays.first(where: { $0.id == item.id })?.text ?? ""
          },
          set: { newValue in
            guard
              let currentIndex = project.overlays.firstIndex(where: {
                $0.id == item.id
              }),
              project.overlays[currentIndex].text != newValue
            else { return }
            project.recordUndoCheckpoint()
            project.overlays[currentIndex].text = newValue
          }
        ),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .labelsHidden()
      .lineLimit(1...2)
      .simultaneousGesture(
        TapGesture().onEnded {
          project.selectOverlay(id: item.id, seekToStart: true)
        }
      )
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 6)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.12)
        : Color(nsColor: .controlBackgroundColor).opacity(0.35),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      project.selectOverlay(id: item.id, seekToStart: true)
    }
    .contextMenu {
      Button("Удалить субтитр", role: .destructive) {
        deleteCaption(id: item.id)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "Субтитр \(item.startTime.timestamp), \(item.text ?? "")"
    )
    .id("caption-\(item.id)")
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
        Picker("Шрифт", selection: $project.overlays[index].fontName) {
          ForEach(
            ["Helvetica Neue", "Arial", "Avenir Next", "Georgia", "Menlo"],
            id: \.self
          ) { family in
            Text(family).tag(family)
          }
        }
        Picker("Начертание", selection: $project.overlays[index].fontWeight) {
          ForEach(CaptionFontWeight.allCases) { weight in
            Text(weight.title).tag(weight)
          }
        }
        ColorPicker(
          "Цвет текста",
          selection: colorBinding(
            hex: $project.overlays[index].foregroundHex
          ),
          supportsOpacity: true
        )
        ColorPicker(
          "Цвет подложки",
          selection: colorBinding(
            hex: $project.overlays[index].backgroundHex
          ),
          supportsOpacity: true
        )
        valueSlider(
          "Отступы",
          valueText: "\(Int(project.overlays[index].textPadding.rounded())) pt",
          value: $project.overlays[index].textPadding,
          range: 0...40
        )
        valueSlider(
          "Скругление",
          valueText: "\(Int(project.overlays[index].cornerRadius.rounded())) pt",
          value: $project.overlays[index].cornerRadius,
          range: 0...32
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

  private func captionBinding<Value: Equatable>(
    _ keyPath: WritableKeyPath<OverlayItem, Value>,
    fallback: Value,
    recordsCheckpoint: Bool = false
  ) -> Binding<Value> {
    Binding(
      get: {
        project.overlays.first(where: { $0.kind == .caption })?[
          keyPath: keyPath
        ] ?? fallback
      },
      set: { value in
        let indices = project.overlays.indices.filter {
          project.overlays[$0].kind == .caption
            && project.overlays[$0][keyPath: keyPath] != value
        }
        guard !indices.isEmpty else { return }
        if recordsCheckpoint {
          project.recordUndoCheckpoint()
        }
        for index in indices {
          project.overlays[index][keyPath: keyPath] = value
        }
      }
    )
  }

  private func captionColorBinding(
    _ keyPath: WritableKeyPath<OverlayItem, String>
  ) -> Binding<Color> {
    Binding(
      get: {
        let hex =
          project.overlays.first(where: { $0.kind == .caption })?[
            keyPath: keyPath
          ] ?? "#FFFFFFFF"
        return Color(nsColor: NSColor(hex: hex))
      },
      set: { color in
        let value = NSColor(color).simpleCutHex
        let binding = captionBinding(
          keyPath,
          fallback: "#FFFFFFFF",
          recordsCheckpoint: true
        )
        binding.wrappedValue = value
      }
    )
  }

  private func deleteCaption(id: UUID) {
    project.recordUndoCheckpoint()
    project.overlays.removeAll { $0.id == id }
    if project.selectedOverlayID == id {
      project.selectedOverlayID = nil
    }
  }

  private func colorBinding(hex: Binding<String>) -> Binding<Color> {
    Binding(
      get: { Color(nsColor: NSColor(hex: hex.wrappedValue)) },
      set: { color in
        let value = NSColor(color).simpleCutHex
        guard value != hex.wrappedValue else { return }
        project.recordUndoCheckpoint()
        hex.wrappedValue = value
      }
    )
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
