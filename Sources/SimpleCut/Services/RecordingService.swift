@preconcurrency import AVFoundation
import AppKit
import SwiftUI

enum CaptureRotation: String, CaseIterable, Identifiable {
  case automatic
  case none
  case clockwise90
  case counterclockwise90
  case upsideDown

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Авто"
    case .none: "0°"
    case .clockwise90: "90° вправо"
    case .counterclockwise90: "90° влево"
    case .upsideDown: "180°"
    }
  }

  var systemImage: String {
    switch self {
    case .automatic: "gyroscope"
    case .none: "rectangle"
    case .clockwise90: "rotate.right"
    case .counterclockwise90: "rotate.left"
    case .upsideDown: "arrow.2.circlepath"
    }
  }

  func angle(automaticAngle: CGFloat) -> CGFloat {
    switch self {
    case .automatic: automaticAngle
    case .none: 0
    case .clockwise90: 90
    case .counterclockwise90: 270
    case .upsideDown: 180
    }
  }
}

@MainActor
final class RecordingService: NSObject, ObservableObject {
  @Published var cameras: [AVCaptureDevice] = []
  @Published var microphones: [AVCaptureDevice] = []
  @Published var selectedCameraID: String? {
    didSet {
      guard let selectedCameraID else { return }
      UserDefaults.standard.set(selectedCameraID, forKey: Defaults.cameraID)
    }
  }
  @Published var selectedMicrophoneID: String? {
    didSet {
      guard let selectedMicrophoneID else { return }
      UserDefaults.standard.set(
        selectedMicrophoneID,
        forKey: Defaults.microphoneID
      )
    }
  }
  @Published var isRecording = false
  @Published var countdown: Int?
  @Published var errorMessage: String?
  @Published var captureRotation: CaptureRotation = .automatic {
    didSet {
      UserDefaults.standard.set(
        captureRotation.rawValue,
        forKey: Defaults.captureRotation
      )
    }
  }
  @Published var isMirrored = false {
    didSet {
      UserDefaults.standard.set(isMirrored, forKey: Defaults.isMirrored)
    }
  }

  let session = AVCaptureSession()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let sessionQueue = DispatchQueue(
    label: "app.simplecut.capture-session"
  )
  private var completion: ((URL) -> Void)?
  private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
  private var countdownTask: Task<Void, Never>?

  private enum Defaults {
    static let cameraID = "recording.cameraID"
    static let microphoneID = "recording.microphoneID"
    static let captureRotation = "recording.captureRotation"
    static let isMirrored = "recording.isMirrored"
  }

  var selectedCamera: AVCaptureDevice? {
    cameras.first { $0.uniqueID == selectedCameraID }
  }

  var previewRotationAngle: CGFloat {
    let automatic =
      rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 0
    return captureRotation.angle(automaticAngle: automatic)
  }

  override init() {
    super.init()
    selectedCameraID = UserDefaults.standard.string(forKey: Defaults.cameraID)
    selectedMicrophoneID = UserDefaults.standard.string(
      forKey: Defaults.microphoneID
    )
    if let rawRotation = UserDefaults.standard.string(
      forKey: Defaults.captureRotation
    ), let savedRotation = CaptureRotation(rawValue: rawRotation) {
      captureRotation = savedRotation
    }
    isMirrored = UserDefaults.standard.bool(forKey: Defaults.isMirrored)
    refreshDevices()
  }

  func refreshDevices() {
    let videoDiscovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external],
      mediaType: .video,
      position: .unspecified
    )
    let audioDiscovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    )
    cameras = videoDiscovery.devices
    microphones = audioDiscovery.devices
    if !cameras.contains(where: { $0.uniqueID == selectedCameraID }) {
      selectedCameraID =
        AVCaptureDevice.systemPreferredCamera?.uniqueID
        ?? cameras.first?.uniqueID
    }
    if !microphones.contains(where: {
      $0.uniqueID == selectedMicrophoneID
    }) {
      selectedMicrophoneID = microphones.first?.uniqueID
    }
  }

  func startPreview() async {
    let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
    let audioAllowed = await AVCaptureDevice.requestAccess(for: .audio)
    guard videoAllowed, audioAllowed else {
      errorMessage = "Разрешите доступ к камере и микрофону в настройках macOS."
      return
    }
    configureSession()
    let captureSession = session
    await withCheckedContinuation { continuation in
      sessionQueue.async {
        if !captureSession.isRunning {
          captureSession.startRunning()
        }
        continuation.resume()
      }
    }
  }

  func stopPreview() {
    Task {
      await stopPreviewAndWait()
    }
  }

  func stopPreviewAndWait() async {
    cancelCountdown()
    guard !isRecording else { return }
    let captureSession = session
    guard captureSession.isRunning else { return }
    await withCheckedContinuation { continuation in
      sessionQueue.async {
        if captureSession.isRunning {
          captureSession.stopRunning()
        }
        continuation.resume()
      }
    }
  }

  func reconfigure() {
    guard !isRecording else { return }
    configureSession()
  }

  func applyVideoSettings() {
    guard !isRecording,
      let connection = movieOutput.connection(with: .video)
    else { return }
    let automatic =
      rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
    let angle = captureRotation.angle(automaticAngle: automatic)
    if connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    }
  }

  func startRecording(
    countdown seconds: Int = 3,
    completion: @escaping (URL) -> Void
  ) {
    guard !movieOutput.isRecording, countdown == nil else { return }
    self.completion = completion
    countdownTask?.cancel()
    countdownTask = Task { [weak self] in
      guard let self else { return }
      for value in stride(from: max(1, seconds), through: 1, by: -1) {
        guard !Task.isCancelled else { return }
        countdown = value
        try? await Task.sleep(for: .seconds(1))
      }
      guard !Task.isCancelled else { return }
      countdown = nil
      beginRecording()
    }
  }

  func cancelCountdown() {
    countdownTask?.cancel()
    countdownTask = nil
    countdown = nil
    if !isRecording {
      completion = nil
    }
  }

  private func beginRecording() {
    guard !movieOutput.isRecording else { return }
    applyVideoSettings()
    do {
      let destination = try MediaLibrary.recordingDestination()
      movieOutput.startRecording(to: destination, recordingDelegate: self)
      isRecording = true
    } catch {
      completion = nil
      errorMessage = error.localizedDescription
    }
  }

  func stopRecording() {
    movieOutput.stopRecording()
  }

  private func configureSession() {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .high
    session.inputs.forEach(session.removeInput)

    if let camera = cameras.first(where: {
      $0.uniqueID == selectedCameraID
    }), let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    {
      session.addInput(input)
      rotationCoordinator = AVCaptureDevice.RotationCoordinator(
        device: camera,
        previewLayer: nil
      )
    }

    if let microphone = microphones.first(where: {
      $0.uniqueID == selectedMicrophoneID
    }), let input = try? AVCaptureDeviceInput(device: microphone),
      session.canAddInput(input)
    {
      session.addInput(input)
    }

    if !session.outputs.contains(where: { $0 === movieOutput }),
      session.canAddOutput(movieOutput)
    {
      session.addOutput(movieOutput)
    }
    applyVideoSettings()
  }
}

extension RecordingService: AVCaptureFileOutputRecordingDelegate {
  nonisolated func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: (any Error)?
  ) {
    Task { @MainActor in
      isRecording = false
      if let error {
        errorMessage = error.localizedDescription
      } else {
        completion?(outputFileURL)
      }
      countdownTask = nil
      completion = nil
    }
  }
}

struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession
  let device: AVCaptureDevice?
  let rotation: CaptureRotation
  let isMirrored: Bool

  func makeNSView(context: Context) -> CapturePreviewView {
    let view = CapturePreviewView()
    view.previewLayer.session = session
    view.apply(device: device, rotation: rotation, isMirrored: isMirrored)
    return view
  }

  func updateNSView(_ nsView: CapturePreviewView, context: Context) {
    nsView.previewLayer.session = session
    nsView.apply(device: device, rotation: rotation, isMirrored: isMirrored)
  }

  static func dismantleNSView(
    _ nsView: CapturePreviewView,
    coordinator: ()
  ) {
    nsView.previewLayer.session = nil
  }
}

final class CapturePreviewView: NSView {
  let previewLayer = AVCaptureVideoPreviewLayer()
  private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
  private var currentRotation: CaptureRotation = .automatic
  private var currentMirroring = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    previewLayer.videoGravity = .resizeAspect
    layer?.addSublayer(previewLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    previewLayer.frame = bounds
    updateConnection()
  }

  func apply(
    device: AVCaptureDevice?,
    rotation: CaptureRotation,
    isMirrored: Bool
  ) {
    currentRotation = rotation
    currentMirroring = isMirrored
    if rotationCoordinator?.device?.uniqueID != device?.uniqueID {
      rotationCoordinator = device.map {
        AVCaptureDevice.RotationCoordinator(
          device: $0,
          previewLayer: previewLayer
        )
      }
    }
    updateConnection()
  }

  private func updateConnection() {
    guard let connection = previewLayer.connection else { return }
    let automatic =
      rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 0
    let angle = currentRotation.angle(automaticAngle: automatic)
    if connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = currentMirroring
    }
  }
}
