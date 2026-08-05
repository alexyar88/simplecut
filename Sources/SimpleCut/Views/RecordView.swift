import SwiftUI

struct RecordView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var project: EditorProject
  @StateObject private var recorder = RecordingService()
  @State private var isFinalizing = false

  var body: some View {
    VStack(spacing: 18) {
      HStack {
        Group {
          if recorder.isRecording {
            Label(
              "Идёт запись · \(recorder.recordingDuration.timestamp)",
              systemImage: "record.circle.fill"
            )
            .foregroundStyle(.red)
          } else {
            Label("Готово к записи", systemImage: "mic.fill")
              .foregroundStyle(.secondary)
          }
        }
        .frame(minWidth: 190, alignment: .leading)
        Spacer()
        ProgressView(value: recorder.microphoneLevel)
          .frame(width: 110)
          .accessibilityLabel("Уровень микрофона")
        Text("Микрофон")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(height: 22)

      HStack(alignment: .top, spacing: 20) {
        ZStack {
          CameraPreview(
            session: recorder.session,
            device: recorder.selectedCamera,
            rotation: recorder.captureRotation,
            isMirrored: recorder.isMirrored,
            mode: recorder.previewMode
          )
          .background(.black)
          .clipShape(RoundedRectangle(cornerRadius: 12))

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
        .aspectRatio(
          project.canvas == .vertical ? 9 / 16 : 16 / 9,
          contentMode: .fit
        )
        .frame(maxWidth: 520, maxHeight: 520)
        .animation(.snappy, value: recorder.countdown)

        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Устройства")
              .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
              Text("Камера")
                .font(.caption)
                .foregroundStyle(.secondary)
              Picker("Камера", selection: $recorder.selectedCameraID) {
                ForEach(recorder.cameras, id: \.uniqueID) { camera in
                  Text(camera.localizedName)
                    .tag(Optional(camera.uniqueID))
                }
              }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Камера")
            }

            VStack(alignment: .leading, spacing: 5) {
              Text("Микрофон")
                .font(.caption)
                .foregroundStyle(.secondary)
              Picker("Микрофон", selection: $recorder.selectedMicrophoneID) {
                ForEach(recorder.microphones, id: \.uniqueID) { microphone in
                  Text(microphone.localizedName)
                    .tag(Optional(microphone.uniqueID))
                }
              }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Микрофон")
            }
          }
          .padding(16)
          .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
          )
          .disabled(recorder.isRecording || recorder.countdown != nil)

          VStack(alignment: .leading, spacing: 12) {
            Text("Изображение")
              .font(.headline)
            Picker("Предпросмотр", selection: $recorder.previewMode) {
              ForEach(CapturePreviewMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
              imageActionButton(
                systemName: "rotate.right",
                title: "Повернуть на 90°"
              ) {
                recorder.rotateClockwise()
              }
              mirrorActionButton
            }
          }
          .padding(16)
          .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .disabled(recorder.isRecording || recorder.countdown != nil)

          Spacer()
          Button {
            if recorder.isRecording {
              recorder.stopRecording()
            } else if recorder.countdown != nil {
              recorder.cancelCountdown()
            } else {
              recorder.startRecording(countdown: 3) { url in
                isFinalizing = true
                project.importVideo(
                  url,
                  copyToLibrary: false
                ) { success in
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
          } label: {
            Label(
              recordButtonTitle,
              systemImage: recorder.isRecording
                ? "stop.fill"
                : recorder.countdown != nil
                  ? "xmark"
                  : "record.circle"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(recorder.isRecording ? .red : .accentColor)
          .keyboardShortcut(.space, modifiers: [])
          .disabled(recorder.cameras.isEmpty)
          .disabled(isFinalizing)
          if isFinalizing {
            ProgressView("Добавляем запись…")
          } else {
            Text("После остановки запись будет добавлена в конец таймлайна.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 360)
      }
      .onChange(of: recorder.selectedCameraID) {
        recorder.reconfigure()
      }
      .onChange(of: recorder.selectedMicrophoneID) {
        recorder.reconfigure()
      }
      .onChange(of: recorder.captureRotation) {
        recorder.applyVideoSettings()
      }
      .onChange(of: recorder.isMirrored) {
        recorder.applyVideoSettings()
      }
    }
    .padding(20)
    .frame(minWidth: 920, minHeight: 620)
    .task {
      await recorder.startPreview()
    }
    .onDisappear {
      if recorder.isRecording {
        recorder.stopRecording()
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

  private var recordButtonTitle: String {
    if recorder.isRecording { return "Остановить запись" }
    if recorder.countdown != nil { return "Отменить" }
    return "Начать запись"
  }

  private func imageActionButton(
    systemName: String,
    title: String,
    isSelected: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemName)
        .lineLimit(1)
    }
    .buttonStyle(RotationButtonStyle(isSelected: isSelected))
    .help(title)
    .accessibilityLabel(title)
  }

  private var mirrorActionButton: some View {
    Button {
      recorder.toggleMirroring()
    } label: {
      Label(
        recorder.isMirrored ? "Зеркально: вкл." : "Зеркально: выкл.",
        systemImage: "arrow.left.and.right"
      )
    }
    .buttonStyle(RotationButtonStyle(isSelected: recorder.isMirrored))
    .help("Отразить зеркально")
    .accessibilityLabel("Отразить зеркально")
  }
}

private struct RotationButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .padding(.horizontal, 5)
      .padding(.vertical, 3)
      .background(
        isSelected
          ? Color.accentColor
          : Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(.separator, lineWidth: isSelected ? 0 : 1)
      }
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
