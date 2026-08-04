import SwiftUI

struct ExportSettingsView: View {
  @Binding var settings: ExportSettings
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

      HStack {
        Spacer()
        Button("Отмена", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Выбрать файл…", action: onExport)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 440)
  }
}
