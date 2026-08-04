import SwiftUI

struct InspectorView: View {
  @EnvironmentObject private var project: EditorProject

  var body: some View {
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
      }
      if !project.clips.isEmpty {
        Section("Звук") {
          Toggle(
            "Нормализация",
            isOn: checkpointedBinding(
              get: { project.audio.normalizeLoudness },
              set: { project.audio.normalizeLoudness = $0 }
            )
          )
          if project.audio.normalizeLoudness {
            LabeledContent(
              "Цель",
              value: "\(Int(project.audio.targetLUFS)) LUFS"
            )
            Slider(
              value: $project.audio.targetLUFS,
              in: -24 ... -9,
              step: 1,
              onEditingChanged: checkpointAtStart
            )
          }
          Toggle(
            "Лимитер",
            isOn: checkpointedBinding(
              get: { project.audio.limiterEnabled },
              set: { project.audio.limiterEnabled = $0 }
            )
          )
          if project.audio.limiterEnabled {
            LabeledContent(
              "Потолок",
              value: String(format: "%.1f dB", project.audio.peakCeilingDB)
            )
            Slider(
              value: $project.audio.peakCeilingDB,
              in: -3 ... -0.1,
              onEditingChanged: checkpointAtStart
            )
          }
          LabeledContent(
            "Усиление",
            value: String(format: "%+.1f dB", project.audio.masterGainDB)
          )
          Slider(
            value: $project.audio.masterGainDB,
            in: -12 ... 12,
            onEditingChanged: checkpointAtStart
          )
        }

        Section("Цвет") {
          colorSlider(
            "Яркость",
            value: $project.color.brightness,
            range: -0.25 ... 0.25
          )
          colorSlider(
            "Контраст",
            value: $project.color.contrast,
            range: 0.5 ... 1.5
          )
          colorSlider(
            "Насыщенность",
            value: $project.color.saturation,
            range: 0 ... 2
          )
          colorSlider(
            "Теплота",
            value: $project.color.warmth,
            range: -1 ... 1
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
          Picker("Модель речи", selection: $project.transcriptionModel) {
            ForEach(TranscriptionModel.allCases) { model in
              Text(model.title).tag(model)
            }
          }
          Button {
            project.generateCaptions()
          } label: {
            Label("Создать субтитры", systemImage: "captions.bubble")
          }
          .disabled(project.isTranscribing)
        }
      }

      if let index = project.selectedOverlayIndex {
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
            Slider(
              value: $project.overlays[index].fontSize,
              in: 20...160,
              onEditingChanged: checkpointAtStart
            ) {
              Text("Размер")
            }
          }
          LabeledContent("Начало") {
            Text(project.overlays[index].startTime.timestamp)
          }
          Slider(
            value: $project.overlays[index].duration,
            in: 0.5...max(0.5, project.duration),
            onEditingChanged: checkpointAtStart
          ) {
            Text("Длительность")
          }
          Slider(
            value: $project.overlays[index].normalizedWidth,
            in: 0.1...1,
            onEditingChanged: checkpointAtStart
          ) {
            Text("Размер")
          }
          Slider(
            value: $project.overlays[index].opacity,
            in: 0...1,
            onEditingChanged: checkpointAtStart
          ) {
            Text("Прозрачность")
          }
          Slider(
            value: $project.overlays[index].rotation,
            in: -180...180,
            onEditingChanged: checkpointAtStart
          ) {
            Text("Поворот")
          }
          Button("Удалить слой", role: .destructive) {
            project.recordUndoCheckpoint()
            project.overlays.remove(at: index)
            project.selectedOverlayID = nil
          }
        }
      } else {
        Section("Подсказка") {
          Text("Добавьте текст или изображение и перетащите его прямо в окне просмотра.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
  }

  private func checkpointAtStart(_ isEditing: Bool) {
    if isEditing {
      project.recordUndoCheckpoint()
    }
  }

  private func checkpointedBinding<T>(
    get: @escaping () -> T,
    set: @escaping (T) -> Void
  ) -> Binding<T> where T: Equatable {
    Binding(
      get: get,
      set: {
        guard $0 != get() else { return }
        project.recordUndoCheckpoint()
        set($0)
      }
    )
  }

  private func colorSlider(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    Slider(
      value: value,
      in: range,
      onEditingChanged: checkpointAtStart
    ) {
      Text(title)
    }
  }

  private func layerTitle(_ kind: OverlayKind) -> String {
    switch kind {
    case .text: "Текст"
    case .caption: "Субтитры"
    case .image: "Изображение"
    }
  }
}
