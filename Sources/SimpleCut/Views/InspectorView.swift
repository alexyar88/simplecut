import SwiftUI

struct InspectorView: View {
  @EnvironmentObject private var project: EditorProject

  var body: some View {
    Form {
      Section("Проект") {
        TextField("Название", text: $project.name)
        Picker("Формат", selection: $project.canvas) {
          ForEach(CanvasPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .onChange(of: project.canvas) {
          Task { try? await project.rebuildPlayback() }
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
                set: { project.overlays[index].text = $0 }
              ),
              axis: .vertical
            )
            Slider(
              value: $project.overlays[index].fontSize,
              in: 20...160
            ) {
              Text("Размер")
            }
          }
          LabeledContent("Начало") {
            Text(project.overlays[index].startTime.timestamp)
          }
          Slider(
            value: $project.overlays[index].duration,
            in: 0.5...max(0.5, project.duration)
          ) {
            Text("Длительность")
          }
          Slider(
            value: $project.overlays[index].normalizedWidth,
            in: 0.1...1
          ) {
            Text("Размер")
          }
          Slider(
            value: $project.overlays[index].opacity,
            in: 0...1
          ) {
            Text("Прозрачность")
          }
          Slider(
            value: $project.overlays[index].rotation,
            in: -180...180
          ) {
            Text("Поворот")
          }
          Button("Удалить слой", role: .destructive) {
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

  private func layerTitle(_ kind: OverlayKind) -> String {
    switch kind {
    case .text: "Текст"
    case .caption: "Субтитры"
    case .image: "Изображение"
    }
  }
}
