import SwiftUI

struct InspectorView: View {
  @EnvironmentObject private var project: EditorProject
  @State private var pendingStyleSave: PendingStyleSave?
  @State private var styleNameDraft = ""
  @State private var currentCaptionStyleName: String?
  @State private var currentTextStyleName: String?

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
              .onAppear {
                scrollToSelectedOverlay(using: proxy)
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
        scrollToSelectedOverlay(using: proxy)
      }
      .onChange(of: project.inspectorFocusRequestID) {
        scrollToSelectedOverlay(using: proxy)
      }
    }
    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
    .background(EditorTheme.panel)
    .alert(
      "Сохранить стиль",
      isPresented: Binding(
        get: { pendingStyleSave != nil },
        set: { isPresented in
          if !isPresented {
            pendingStyleSave = nil
          }
        }
      )
    ) {
      TextField("Название стиля", text: $styleNameDraft)
      Button("Сохранить") {
        savePendingStyle()
      }
      .disabled(styleNameIsEmpty(styleNameDraft))
      Button("Отмена", role: .cancel) {
        pendingStyleSave = nil
      }
    } message: {
      Text("Введите название, под которым сохранить текущие настройки.")
    }
  }

  private func scrollToSelectedOverlay(
    using proxy: ScrollViewProxy
  ) {
    guard let index = project.selectedOverlayIndex else { return }
    let item = project.overlays[index]
    let targetID =
      item.kind == .caption
      ? "caption-\(item.id)"
      : overlayInspectorID(item.id)
    let anchor: UnitPoint = item.kind == .caption ? .center : .top

    Task { @MainActor in
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(20))
      withAnimation {
        proxy.scrollTo(
          targetID,
          anchor: anchor
        )
      }
    }
  }

  private func overlayInspectorID(_ id: UUID) -> String {
    "overlay-\(id)"
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

  @ViewBuilder
  private var captionSettingsSection: some View {
    if let id = project.overlays.first(where: {
      $0.kind == .caption
    })?.id {
      Section("Оформление субтитров") {
        Picker(
          "Шрифт",
          selection: captionBinding(
            \.fontName,
            fallback: "Helvetica Neue",
            recordsCheckpoint: true
          )
        ) {
          ForEach(fontFamilies, id: \.self) { family in
            Text(family).tag(family)
          }
        }
        .pickerStyle(.menu)
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
        .pickerStyle(.menu)
        alignmentPicker(
          selection: captionBinding(
            \.textAlignment,
            fallback: .center,
            recordsCheckpoint: true
          )
        )
        inspectorSlider(
          "Размер шрифта",
          value: captionBinding(\.fontSize, fallback: 58),
          range: 20...160,
          suffix: " pt"
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
        inspectorSlider(
          "Толщина обводки",
          value: captionBinding(\.strokeWidth, fallback: 0),
          range: 0...12,
          suffix: " pt"
        )
        inspectorSlider(
          "Отступы",
          value: captionBinding(\.textPadding, fallback: 12),
          range: 0...40,
          suffix: " pt"
        )
        inspectorSlider(
          "Скругление",
          value: captionBinding(\.cornerRadius, fallback: 8),
          range: 0...32,
          suffix: " pt"
        )
        inspectorSlider(
          "Ширина",
          value: captionBinding(\.normalizedWidth, fallback: 0.82),
          range: 0.25...1,
          displayScale: 100,
          suffix: "%"
        )
        Divider()
        quickStyleMenu(kind: .caption, overlayID: id)
        styleActionRow(kind: .caption, overlayID: id)
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
    let item = project.overlays[index]
    if item.kind == .text {
      Section("Текст") {
        textEditor(index: index)
        Picker("Шрифт", selection: $project.overlays[index].fontName) {
          ForEach(fontFamilies, id: \.self) { family in
            Text(family).tag(family)
          }
        }
        .pickerStyle(.menu)
        Picker(
          "Начертание",
          selection: $project.overlays[index].fontWeight
        ) {
          ForEach(CaptionFontWeight.allCases) { weight in
            Text(weight.title).tag(weight)
          }
        }
        .pickerStyle(.menu)
        alignmentPicker(
          selection: $project.overlays[index].textAlignment
        )
        inspectorSlider(
          "Размер шрифта",
          value: $project.overlays[index].fontSize,
          range: 20...160,
          suffix: " pt"
        )
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
        ColorPicker(
          "Цвет обводки",
          selection: colorBinding(
            hex: $project.overlays[index].strokeHex
          ),
          supportsOpacity: true
        )
        inspectorSlider(
          "Толщина обводки",
          value: $project.overlays[index].strokeWidth,
          range: 0...12,
          suffix: " pt"
        )
        inspectorSlider(
          "Отступы",
          value: $project.overlays[index].textPadding,
          range: 0...40,
          suffix: " pt"
        )
        inspectorSlider(
          "Скругление",
          value: $project.overlays[index].cornerRadius,
          range: 0...32,
          suffix: " pt"
        )
        transformControls(index: index, minimumWidth: 0.25)
        Divider()
        quickStyleMenu(kind: .text, overlayID: item.id)
        styleActionRow(kind: .text, overlayID: item.id)
      }
      .id(overlayInspectorID(item.id))
    } else if item.kind == .image {
      Section("Изображение") {
        transformControls(index: index, minimumWidth: 0.1)
      }
      .id(overlayInspectorID(item.id))
    }
  }

  private var fontFamilies: [String] {
    ["Helvetica Neue", "Arial", "Avenir Next", "Georgia", "Menlo"]
  }

  private func textEditor(index: Int) -> some View {
    let text = Binding(
      get: { project.overlays[index].text ?? "" },
      set: { newValue in
        guard newValue != project.overlays[index].text else { return }
        project.recordUndoCheckpoint()
        project.overlays[index].text = newValue
      }
    )
    return ZStack(alignment: .topLeading) {
      if text.wrappedValue.isEmpty {
        Text("Введите текст…")
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 9)
          .padding(.vertical, 10)
          .allowsHitTesting(false)
      }
      TextEditor(text: text)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(4)
    }
    .frame(minHeight: 88, maxHeight: 150)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.55),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    }
    .accessibilityLabel("Текст слоя")
  }

  private func quickStyleMenu(
    kind: OverlayKind,
    overlayID: UUID
  ) -> some View {
    Menu {
      ForEach(CaptionStylePreset.allCases) { preset in
        Button(preset.title) {
          if kind == .caption {
            project.applyCaptionPreset(preset)
          } else {
            project.applyPreset(preset, to: overlayID)
          }
          setCurrentStyleName(nil, for: kind)
        }
      }
      let styles = project.styles(for: kind)
      if !styles.isEmpty {
        Divider()
        ForEach(styles) { savedStyle in
          Button(savedStyle.name) {
            project.applySavedStyle(
              named: savedStyle.name,
              to: overlayID
            )
            setCurrentStyleName(savedStyle.name, for: kind)
          }
        }
      }
    } label: {
      HStack {
        Text(currentStyleName(for: kind) ?? "Быстрый стиль")
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
  }

  private func alignmentPicker(
    selection: Binding<OverlayTextAlignment>
  ) -> some View {
    LabeledContent("Выравнивание") {
      Picker("Выравнивание", selection: selection) {
        ForEach(OverlayTextAlignment.allCases) { alignment in
          Image(systemName: alignment.systemImage)
            .help(alignment.title)
            .tag(alignment)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 118)
    }
  }

  @ViewBuilder
  private func transformControls(
    index: Int,
    minimumWidth: Double
  ) -> some View {
    inspectorSlider(
      "Ширина",
      value: $project.overlays[index].normalizedWidth,
      range: minimumWidth...1,
      displayScale: 100,
      suffix: "%"
    )
    inspectorSlider(
      "Прозрачность",
      value: $project.overlays[index].opacity,
      range: 0...1,
      displayScale: 100,
      suffix: "%"
    )
    inspectorSlider(
      "Поворот",
      value: $project.overlays[index].rotation,
      range: -180...180,
      suffix: "°"
    )
  }

  private func styleNameIsEmpty(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func styleActionRow(
    kind: OverlayKind,
    overlayID: UUID
  ) -> some View {
    let currentName = currentStyleName(for: kind)
    let canDelete =
      currentName.map { name in
        project.styles(for: kind).contains { $0.name == name }
      } ?? false
    return HStack(spacing: 8) {
      Button("Сохранить стиль") {
        beginSavingStyle(kind: kind, overlayID: overlayID)
      }
      .buttonStyle(.bordered)
      Button("Удалить стиль", role: .destructive) {
        guard let currentName else { return }
        project.deleteStyle(named: currentName, for: kind)
        setCurrentStyleName(nil, for: kind)
      }
      .buttonStyle(.bordered)
      .tint(.red)
      .disabled(!canDelete)
    }
  }

  private func currentStyleName(for kind: OverlayKind) -> String? {
    kind == .caption
      ? currentCaptionStyleName
      : currentTextStyleName
  }

  private func setCurrentStyleName(
    _ name: String?,
    for kind: OverlayKind
  ) {
    if kind == .caption {
      currentCaptionStyleName = name
    } else {
      currentTextStyleName = name
    }
  }

  private func inspectorSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    displayScale: Double = 1,
    suffix: String = "",
    fractionDigits: Int = 0
  ) -> some View {
    InspectorValueSlider(
      title: title,
      value: value,
      range: range,
      displayScale: displayScale,
      suffix: suffix,
      fractionDigits: fractionDigits,
      onEditingStarted: {
        project.recordUndoCheckpoint()
      }
    )
  }

  private func colorSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    inspectorSlider(
      title,
      value: value,
      range: range,
      fractionDigits: 2
    )
  }

  private func beginSavingStyle(
    kind: OverlayKind,
    overlayID: UUID
  ) {
    styleNameDraft = nextStyleName(for: kind)
    pendingStyleSave = PendingStyleSave(
      kind: kind,
      overlayID: overlayID
    )
  }

  private func savePendingStyle() {
    guard let pendingStyleSave else { return }
    let name = styleNameDraft.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !name.isEmpty else { return }
    project.saveStyle(
      named: name,
      from: pendingStyleSave.overlayID
    )
    setCurrentStyleName(name, for: pendingStyleSave.kind)
    self.pendingStyleSave = nil
  }

  private func nextStyleName(for kind: OverlayKind) -> String {
    let existingNames = Set(
      project.styles(for: kind).map {
        $0.name.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: .current
        )
      }
    )
    var index = 1
    while existingNames.contains(
      "Мой стиль \(index)".folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
    ) {
      index += 1
    }
    return "Мой стиль \(index)"
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

}

private struct PendingStyleSave {
  let kind: OverlayKind
  let overlayID: UUID
}

private struct InspectorValueSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let displayScale: Double
  let suffix: String
  let fractionDigits: Int
  let onEditingStarted: () -> Void
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
        Spacer()
        TextField("", text: $draft)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 72)
          .focused($isFocused)
          .onSubmit {
            commit()
            isFocused = false
          }
      }
      Slider(
        value: $value,
        in: range,
        onEditingChanged: { isEditing in
          if isEditing {
            onEditingStarted()
          }
        }
      )
      .accessibilityLabel(title)
      .accessibilityValue(formattedValue)
    }
    .onAppear { synchronizeDraft() }
    .onChange(of: value) {
      if !isFocused {
        synchronizeDraft()
      }
    }
    .onChange(of: isFocused) {
      if !isFocused {
        commit()
      }
    }
  }

  private var formattedValue: String {
    String(
      format: "%.\(fractionDigits)f",
      value * displayScale
    ) + suffix
  }

  private func synchronizeDraft() {
    draft = formattedValue
  }

  private func commit() {
    let normalized = draft
      .replacingOccurrences(of: suffix, with: "")
      .replacingOccurrences(of: ",", with: ".")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = Double(normalized) else {
      synchronizeDraft()
      return
    }
    let rawValue = parsed / max(displayScale, 0.0001)
    let clamped = min(max(rawValue, range.lowerBound), range.upperBound)
    if abs(clamped - value) > 0.0001 {
      onEditingStarted()
      value = clamped
    }
    synchronizeDraft()
  }
}
