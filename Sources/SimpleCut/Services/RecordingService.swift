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

  func connectionAngle(
    automaticAngle: CGFloat,
    mirrored: Bool
  ) -> CGFloat {
    let visualAngle = angle(automaticAngle: automaticAngle)
    guard mirrored else { return visualAngle }
    return (360 - visualAngle).truncatingRemainder(dividingBy: 360)
  }

  var rotatedClockwise: CaptureRotation {
    switch self {
    case .automatic, .none: .clockwise90
    case .clockwise90: .upsideDown
    case .upsideDown: .counterclockwise90
    case .counterclockwise90: .none
    }
  }

  var rotatedCounterclockwise: CaptureRotation {
    switch self {
    case .automatic, .none: .counterclockwise90
    case .counterclockwise90: .upsideDown
    case .upsideDown: .clockwise90
    case .clockwise90: .none
    }
  }
}

enum CapturePreviewMode: String, CaseIterable, Identifiable {
  case fit
  case fill

  var id: String { rawValue }
  var title: String {
    switch self {
    case .fit: "Вписать"
    case .fill: "Заполнить"
    }
  }
}

enum CaptureQuality: String, CaseIterable, Identifiable {
  case hd720
  case hd1080
  case uhd4K

  var id: String { rawValue }

  var title: String {
    switch self {
    case .hd720: "720p"
    case .hd1080: "1080p"
    case .uhd4K: "4K"
    }
  }

  var sessionPreset: AVCaptureSession.Preset {
    switch self {
    case .hd720: .hd1280x720
    case .hd1080: .hd1920x1080
    case .uhd4K: .hd4K3840x2160
    }
  }

  var estimatedMegabytesPerMinute: Double {
    switch self {
    case .hd720: 70
    case .hd1080: 140
    case .uhd4K: 420
    }
  }
}

enum CaptureFrameRate: Int, CaseIterable, Identifiable {
  case fps24 = 24
  case fps30 = 30
  case fps60 = 60

  var id: Int { rawValue }
  var title: String { "\(rawValue) fps" }
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
  @Published var isStartingRecording = false
  @Published var recordingDuration = 0.0
  @Published var microphoneLevel = 0.0
  @Published var previewMode: CapturePreviewMode = .fit
  @Published var quality: CaptureQuality = .hd1080 {
    didSet {
      UserDefaults.standard.set(quality.rawValue, forKey: Defaults.quality)
    }
  }
  @Published var frameRate: CaptureFrameRate = .fps30 {
    didSet {
      UserDefaults.standard.set(frameRate.rawValue, forKey: Defaults.frameRate)
    }
  }
  @Published var countdown: Int?
  @Published var errorMessage: String?
  @Published var outputDirectory: URL?
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
  private let audioLevelOutput = AVCaptureAudioDataOutput()
  private let audioMeter = AudioLevelMonitor()
  private let sessionQueue = DispatchQueue(
    label: "app.simplecut.capture-session"
  )
  private let audioMeterQueue = DispatchQueue(
    label: "app.simplecut.audio-meter",
    qos: .userInteractive
  )
  private var completion: ((URL) -> Void)?
  private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
  private var countdownTask: Task<Void, Never>?
  private var meteringTask: Task<Void, Never>?
  private var recordedDurationOffset = 0.0
  private var shouldDiscardRecording = false

  private enum Defaults {
    static let cameraID = "recording.cameraID"
    static let microphoneID = "recording.microphoneID"
    static let captureRotation = "recording.captureRotation"
    static let isMirrored = "recording.isMirrored"
    static let quality = "recording.quality"
    static let frameRate = "recording.frameRate"
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
    if let rawQuality = UserDefaults.standard.string(forKey: Defaults.quality),
      let savedQuality = CaptureQuality(rawValue: rawQuality)
    {
      quality = savedQuality
    }
    if UserDefaults.standard.object(forKey: Defaults.frameRate) != nil,
      let savedFrameRate = CaptureFrameRate(
        rawValue: UserDefaults.standard.integer(forKey: Defaults.frameRate)
      )
    {
      frameRate = savedFrameRate
    }
    isMirrored = UserDefaults.standard.bool(forKey: Defaults.isMirrored)
    audioMeter.onLevel = { [weak self] level in
      Task { @MainActor [weak self] in
        self?.microphoneLevel = Double(level)
      }
    }
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
    startMetering()
  }

  func stopPreview() {
    Task {
      await stopPreviewAndWait()
    }
  }

  func stopPreviewAndWait() async {
    cancelCountdown()
    guard !isRecording, !isStartingRecording else { return }
    meteringTask?.cancel()
    meteringTask = nil
    microphoneLevel = 0
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
    guard !isRecording, !isStartingRecording else { return }
    configureSession()
  }

  func applyVideoSettings() {
    guard !isRecording, !isStartingRecording,
      let connection = movieOutput.connection(with: .video)
    else { return }
    let automatic =
      rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
    let angle = captureRotation.connectionAngle(
      automaticAngle: automatic,
      mirrored: isMirrored
    )
    if connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    }
  }

  func rotateClockwise() {
    if captureRotation == .automatic {
      captureRotation = explicitRotation(for: previewRotationAngle)
        .rotatedClockwise
    } else {
      captureRotation = captureRotation.rotatedClockwise
    }
    applyVideoSettings()
  }

  func rotateCounterclockwise() {
    captureRotation = captureRotation.rotatedCounterclockwise
  }

  func toggleMirroring() {
    isMirrored.toggle()
  }

  func startRecording(
    countdown seconds: Int = 3,
    completion: @escaping (URL) -> Void
  ) {
    guard !movieOutput.isRecording, !isStartingRecording, countdown == nil else {
      return
    }
    self.completion = completion
    countdownTask?.cancel()
    if seconds <= 0 {
      countdown = nil
      beginRecording()
      return
    }
    countdownTask = Task { [weak self] in
      guard let self else { return }
      for value in stride(from: seconds, through: 1, by: -1) {
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
      let destination = try MediaLibrary.recordingDestination(
        in: outputDirectory
      )
      isStartingRecording = true
      shouldDiscardRecording = false
      recordingDuration = 0
      recordedDurationOffset = 0
      movieOutput.startRecording(to: destination, recordingDelegate: self)
      startMetering()
    } catch {
      isStartingRecording = false
      completion = nil
      errorMessage = error.localizedDescription
    }
  }

  func stopRecording() {
    if movieOutput.isRecording {
      movieOutput.stopRecording()
    }
  }

  func cancelRecordingStart() {
    guard isStartingRecording else { return }
    shouldDiscardRecording = true
    completion = nil
    movieOutput.stopRecording()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, shouldDiscardRecording, !movieOutput.isRecording else {
        return
      }
      isStartingRecording = false
      shouldDiscardRecording = false
    }
  }

  private func startMetering() {
    guard meteringTask == nil else { return }
    meteringTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if isRecording {
          let seconds = CMTimeGetSeconds(movieOutput.recordedDuration)
          recordingDuration = seconds.isFinite
            ? max(0, seconds - recordedDurationOffset)
            : 0
        }
        try? await Task.sleep(for: .milliseconds(33))
      }
    }
  }

  private func configureSession() {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = session.canSetSessionPreset(quality.sessionPreset)
      ? quality.sessionPreset
      : .high
    session.inputs.forEach(session.removeInput)

    if let camera = cameras.first(where: {
      $0.uniqueID == selectedCameraID
    }), let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    {
      session.addInput(input)
      configureFrameRate(for: camera)
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
    if !session.outputs.contains(where: { $0 === audioLevelOutput }),
      session.canAddOutput(audioLevelOutput)
    {
      audioLevelOutput.audioSettings = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      session.addOutput(audioLevelOutput)
      audioLevelOutput.setSampleBufferDelegate(
        audioMeter,
        queue: audioMeterQueue
      )
    }
    applyVideoSettings()
  }

  private func configureFrameRate(for camera: AVCaptureDevice) {
    let requested = Double(frameRate.rawValue)
    let supported = camera.activeFormat.videoSupportedFrameRateRanges
      .contains { $0.minFrameRate <= requested && requested <= $0.maxFrameRate }
    guard supported else { return }
    do {
      try camera.lockForConfiguration()
      let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
      camera.activeVideoMinFrameDuration = duration
      camera.activeVideoMaxFrameDuration = duration
      camera.unlockForConfiguration()
    } catch {
      errorMessage = "Не удалось установить \(frameRate.title): \(error.localizedDescription)"
    }
  }

  private func explicitRotation(for angle: CGFloat) -> CaptureRotation {
    let normalized = Int(angle.rounded() + 360) % 360
    switch normalized {
    case 45..<135: return .clockwise90
    case 135..<225: return .upsideDown
    case 225..<315: return .counterclockwise90
    default: return .none
    }
  }
}

private final class AudioLevelMonitor:
  NSObject,
  AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  var onLevel: (@Sendable (Float) -> Void)?

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      return
    }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    guard length > 1 else { return }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
      return CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: length,
        destination: baseAddress
      )
    }
    guard status == kCMBlockBufferNoErr else { return }

    let rms: Float = data.withUnsafeBytes { bytes in
      let samples = bytes.bindMemory(to: Int16.self)
      guard !samples.isEmpty else { return 0 }
      var sum: Double = 0
      for sample in samples {
        let normalized = Double(sample) / Double(Int16.max)
        sum += normalized * normalized
      }
      return Float(sqrt(sum / Double(samples.count)))
    }
    let decibels = rms > 0 ? 20 * log10(rms) : -60
    let normalized = min(1, max(0, (decibels + 52) / 52))
    let gated = normalized < 0.12 ? 0 : normalized
    let stepped = (gated * 24).rounded() / 24
    onLevel?(stepped)
  }
}

extension RecordingService: AVCaptureFileOutputRecordingDelegate {
  nonisolated func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    Task { @MainActor in
      if shouldDiscardRecording {
        output.stopRecording()
        isStartingRecording = false
        return
      }
      let seconds = CMTimeGetSeconds(output.recordedDuration)
      recordedDurationOffset = seconds.isFinite ? max(0, seconds) : 0
      recordingDuration = 0
      isStartingRecording = false
      isRecording = true
    }
  }

  nonisolated func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: (any Error)?
  ) {
    Task { @MainActor in
      isRecording = false
      isStartingRecording = false
      recordingDuration = 0
      recordedDurationOffset = 0
      if shouldDiscardRecording {
        try? FileManager.default.removeItem(at: outputFileURL)
      } else if let error {
        errorMessage = error.localizedDescription
      } else {
        completion?(outputFileURL)
      }
      shouldDiscardRecording = false
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
  let mode: CapturePreviewMode

  func makeNSView(context: Context) -> CapturePreviewView {
    let view = CapturePreviewView()
    view.previewLayer.session = session
    view.apply(
      device: device,
      rotation: rotation,
      isMirrored: isMirrored,
      mode: mode
    )
    return view
  }

  func updateNSView(_ nsView: CapturePreviewView, context: Context) {
    nsView.previewLayer.session = session
    nsView.apply(
      device: device,
      rotation: rotation,
      isMirrored: isMirrored,
      mode: mode
    )
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
    previewLayer.bounds = bounds
    previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    updateConnection()
  }

  func apply(
    device: AVCaptureDevice?,
    rotation: CaptureRotation,
    isMirrored: Bool,
    mode: CapturePreviewMode
  ) {
    previewLayer.videoGravity = mode == .fill ? .resizeAspectFill : .resizeAspect
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
    previewLayer.setAffineTransform(
      CGAffineTransform(scaleX: currentMirroring ? -1 : 1, y: 1)
    )
    guard let connection = previewLayer.connection else { return }
    let automatic =
      rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 0
    let angle = currentRotation.angle(automaticAngle: automatic)
    if connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = false
    }
  }
}
