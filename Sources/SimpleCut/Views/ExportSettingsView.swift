import SwiftUI

struct ExportSettingsView: View {
  @Binding var settings: ExportSettings
  let canvas: CanvasPreset
  let duration: Double
  let projectName: String
  let onExport: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Экспорт видео")
        .font(.title2.bold())

      Form {
        Picker("Кодек и качество", selection: $settings.quality) {
          ForEach(ExportQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }
        Text(settings.quality.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("Разрешение", selection: $settings.resolution) {
          ForEach(ExportResolution.allCases) { resolution in
            Text(resolution.title).tag(resolution)
          }
        }
        Picker("Частота кадров", selection: $settings.framesPerSecond) {
          Text("24 fps").tag(24)
          Text("30 fps").tag(30)
          Text("60 fps").tag(60)
        }
      }
      .formStyle(.grouped)

      GroupBox("Итоговый файл") {
        let size = settings.outputSize(for: canvas)
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
          GridRow {
            Text("Имя")
              .foregroundStyle(.secondary)
            Text(suggestedFileName)
          }
          GridRow {
            Text("Размер кадра")
              .foregroundStyle(.secondary)
            Text("\(Int(size.width)) × \(Int(size.height))")
          }
          GridRow {
            Text("Длительность")
              .foregroundStyle(.secondary)
            Text(duration.timestamp)
          }
          GridRow {
            Text("Оценка размера")
              .foregroundStyle(.secondary)
            Text(settings.estimatedFileSize(duration: duration))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text("Имя и папку назначения можно изменить на следующем шаге.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Отмена", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Экспортировать…", action: onExport)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 480)
  }

  private var suggestedFileName: String {
    let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(trimmed.isEmpty ? "SimpleCut" : trimmed).mp4"
  }
}
