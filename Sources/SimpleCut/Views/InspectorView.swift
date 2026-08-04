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

  private func layerTitle(_ kind: OverlayKind) -> String {
    switch kind {
    case .text: "Текст"
    case .caption: "Субтитры"
    case .image: "Изображение"
    }
  }
}
