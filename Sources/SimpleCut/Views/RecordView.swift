import SwiftUI

struct RecordView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var project: EditorProject
  @StateObject private var recorder = RecordingService()
  @State private var isFinalizing = false

  var body: some View {
    VStack(spacing: 18) {
      HStack {
        Text("Запись")
          .font(.title2.bold())
        if recorder.isRecording {
          Label("Идёт запись", systemImage: "record.circle.fill")
            .foregroundStyle(.red)
        }
        Spacer()
        Button("Закрыть") {
          isFinalizing = true
          Task {
            await recorder.stopPreviewAndWait()
            dismiss()
          }
        }
          .disabled(recorder.isRecording || isFinalizing)
          .help(
            recorder.isRecording || isFinalizing
              ? "Дождитесь завершения записи"
              : "Закрыть окно записи"
          )
      }

      HStack(alignment: .top, spacing: 20) {
        ZStack {
          CameraPreview(
            session: recorder.session,
            device: recorder.selectedCamera,
            rotation: recorder.captureRotation,
            isMirrored: recorder.isMirrored
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

        VStack(spacing: 14) {
          Group {
            GroupBox("Устройства") {
              VStack(alignment: .leading, spacing: 12) {
                Picker("Камера", selection: $recorder.selectedCameraID) {
                  ForEach(recorder.cameras, id: \.uniqueID) { camera in
                    Text(camera.localizedName)
                      .tag(Optional(camera.uniqueID))
                  }
                }
                Picker("Микрофон", selection: $recorder.selectedMicrophoneID) {
                  ForEach(recorder.microphones, id: \.uniqueID) { microphone in
                    Text(microphone.localizedName)
                      .tag(Optional(microphone.uniqueID))
                  }
                }
              }
              .padding(.vertical, 4)
            }

            GroupBox("Изображение") {
              VStack(alignment: .leading, spacing: 12) {
                Text("Поворот")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                  ForEach(CaptureRotation.allCases) { rotation in
                    Button {
                      recorder.captureRotation = rotation
                    } label: {
                      Image(systemName: rotation.systemImage)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(
                      RotationButtonStyle(
                        isSelected: recorder.captureRotation == rotation
                      )
                    )
                    .help(rotation.title)
                    .accessibilityLabel(rotation.title)
                  }
                }
                Toggle("Отразить зеркально", isOn: $recorder.isMirrored)
                  .help("Preview и записанный файл отражаются одинаково")
              }
              .padding(.vertical, 4)
            }
          }
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
          .disabled(recorder.cameras.isEmpty)
          .disabled(isFinalizing)
          if isFinalizing {
            ProgressView("Добавляем запись…")
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
      recorder.stopPreview()
    }
    .interactiveDismissDisabled(recorder.isRecording || isFinalizing)
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
