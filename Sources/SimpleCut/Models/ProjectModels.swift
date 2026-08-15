import CoreGraphics
import Foundation

enum CanvasPreset: String, Codable, CaseIterable, Identifiable {
  case vertical
  case horizontal
  case square

  var id: String { rawValue }

  var title: String {
    switch self {
    case .vertical: "Вертикальный · 9:16"
    case .horizontal: "Горизонтальный · 16:9"
    case .square: "Квадратный · 1:1"
    }
  }

  var size: CGSize {
    switch self {
    case .vertical: CGSize(width: 1080, height: 1920)
    case .horizontal: CGSize(width: 1920, height: 1080)
    case .square: CGSize(width: 1080, height: 1080)
    }
  }

  var aspectRatio: CGFloat {
    size.width / size.height
  }

  /// Editing uses fewer pixels than export. The dimensions stay even so they
  /// remain suitable for hardware-backed video pipelines.
  var previewSize: CGSize {
    let maximumDimension: CGFloat = 960
    let scale = min(1, maximumDimension / max(size.width, size.height))
    func even(_ value: CGFloat) -> CGFloat {
      max(2, (value * scale / 2).rounded() * 2)
    }
    return CGSize(width: even(size.width), height: even(size.height))
  }

  /// A conservative content area that stays clear of the controls used by
  /// short-form social video players. Coordinates use the preview's top-left
  /// origin and are normalized to the canvas.
  var socialSafeArea: CGRect? {
    guard self == .vertical else { return nil }
    return CGRect(x: 0.07, y: 0.08, width: 0.86, height: 0.67)
  }
}

enum VideoScalingMode: String, Codable, CaseIterable, Identifiable {
  case fit
  case fill

  var id: String { rawValue }
  var title: String {
    switch self {
    case .fit: "Вписать целиком"
    case .fill: "Заполнить с обрезкой"
    }
  }
}

struct VideoClip: Identifiable, Codable, Equatable {
  var id = UUID()
  var sourceURL: URL
  var sourceStart: Double
  var duration: Double
  var sourceDuration: Double? = nil

  var sourceEnd: Double { sourceStart + duration }
}

struct AudioSettings: Codable, Equatable {
  var normalizeLoudness = false
  var limiterEnabled = true
  var peakCeilingDB = -1.0
}

struct ColorSettings: Codable, Equatable {
  var brightness = 0.0
  var contrast = 1.0
  var saturation = 1.0
  var warmth = 0.0

  var isNeutral: Bool {
    abs(brightness) < 0.0001
      && abs(contrast - 1) < 0.0001
      && abs(saturation - 1) < 0.0001
      && abs(warmth) < 0.0001
  }

  static let neutral = ColorSettings()
  static let automatic = ColorSettings(
    brightness: 0.035,
    contrast: 1.08,
    saturation: 1.06,
    warmth: 0.08
  )
}

enum ExportQuality: String, CaseIterable, Identifiable {
  case compatible
  case efficient
  case compact

  var id: String { rawValue }

  var title: String {
    switch self {
    case .compatible: "H.264 · совместимый"
    case .efficient: "HEVC · высокое качество"
    case .compact: "H.264 · компактный"
    }
  }

  var detail: String {
    switch self {
    case .compatible: "Лучший выбор для отправки и публикации."
    case .efficient: "Меньше размер при высоком качестве; совместимость ниже."
    case .compact: "Самый небольшой файл с умеренным качеством."
    }
  }

  var estimatedMegabitsPerSecond: Double {
    switch self {
    case .compatible: 12
    case .efficient: 8
    case .compact: 5
    }
  }
}

enum ExportResolution: String, CaseIterable, Identifiable {
  case small
  case hd
  case fourK

  var id: String { rawValue }

  var title: String {
    switch self {
    case .small: "720p"
    case .hd: "1080p"
    case .fourK: "2160p"
    }
  }

  var scale: Double {
    switch self {
    case .small: 2.0 / 3.0
    case .hd: 1
    case .fourK: 2
    }
  }
}

struct ExportSettings: Equatable {
  var quality: ExportQuality = .compatible
  var resolution: ExportResolution = .hd
  var framesPerSecond = 30

  func outputSize(for canvas: CanvasPreset) -> CGSize {
    CGSize(
      width: (canvas.size.width * resolution.scale).rounded(),
      height: (canvas.size.height * resolution.scale).rounded()
    )
  }

  func estimatedFileSize(duration: Double) -> String {
    let resolutionFactor = pow(resolution.scale, 2)
    let frameRateFactor = Double(framesPerSecond) / 30
    let megabytes =
      quality.estimatedMegabitsPerSecond * resolutionFactor * frameRateFactor
      * max(0, duration) / 8
    if megabytes >= 1024 {
      return String(format: "≈ %.1f ГБ", megabytes / 1024)
    }
    return String(format: "≈ %.0f МБ", max(1, megabytes))
  }
}

enum OverlayKind: String, Codable, CaseIterable {
  case text
  case image
  case caption

  var isTextual: Bool {
    self != .image
  }

  var compositingRank: Int {
    switch self {
    case .image: 0
    case .caption: 1
    case .text: 2
    }
  }

  static let timelineOrder: [OverlayKind] = [
    .text,
    .caption,
    .image,
  ]

  static func timelineKinds(for overlays: [OverlayItem]) -> [OverlayKind] {
    timelineOrder.filter { kind in
      overlays.contains { $0.kind == kind }
    }
  }
}

enum CaptionFontWeight: String, Codable, CaseIterable, Identifiable {
  case regular
  case semibold
  case bold
  case heavy

  var id: String { rawValue }

  var title: String {
    switch self {
    case .regular: "Обычный"
    case .semibold: "Полужирный"
    case .bold: "Жирный"
    case .heavy: "Очень жирный"
    }
  }
}

enum OverlayTextAlignment: String, Codable, CaseIterable, Identifiable {
  case left
  case center
  case right

  var id: String { rawValue }

  var title: String {
    switch self {
    case .left: "По левому краю"
    case .center: "По центру"
    case .right: "По правому краю"
    }
  }

  var systemImage: String {
    switch self {
    case .left: "text.alignleft"
    case .center: "text.aligncenter"
    case .right: "text.alignright"
    }
  }
}

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
  case base
  case accurate = "large-v3-v20240930_626MB"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .base: "Быстро · Base"
    case .accurate: "Точно · Large v3"
    }
  }

  var downloadHint: String {
    switch self {
    case .base: "Около 150 МБ при первом запуске"
    case .accurate: "Около 626 МБ при первом запуске"
    }
  }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case russian
  case english

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Авто"
    case .russian: "Русский"
    case .english: "Английский"
    }
  }

  var whisperCode: String? {
    switch self {
    case .automatic: nil
    case .russian: "ru"
    case .english: "en"
    }
  }
}

struct OverlayItem: Identifiable, Codable, Equatable {
  var id = UUID()
  var kind: OverlayKind
  var startTime: Double
  var duration: Double
  var normalizedX: Double = 0.5
  var normalizedY: Double = 0.5
  var normalizedWidth: Double = 0.5
  var rotation: Double = 0
  var opacity: Double = 1
  var text: String?
  var imageURL: URL?
  var fontSize: Double = 64
  var fontName: String = "Helvetica Neue"
  var fontWeight: CaptionFontWeight = .semibold
  var textAlignment: OverlayTextAlignment = .center
  var foregroundHex: String = "#FFFFFF"
  var backgroundHex: String = "#00000099"
  var strokeHex: String = "#000000FF"
  var strokeWidth: Double = 0
  var textPadding: Double = 12
  var cornerRadius: Double = 8

  enum CodingKeys: String, CodingKey {
    case id, kind, startTime, duration, normalizedX, normalizedY
    case normalizedWidth, rotation, opacity, text, imageURL, fontSize
    case fontName, fontWeight, textAlignment, foregroundHex, backgroundHex
    case strokeHex, strokeWidth, textPadding, cornerRadius
  }

  init(
    id: UUID = UUID(),
    kind: OverlayKind,
    startTime: Double,
    duration: Double,
    normalizedX: Double = 0.5,
    normalizedY: Double = 0.5,
    normalizedWidth: Double = 0.5,
    rotation: Double = 0,
    opacity: Double = 1,
    text: String? = nil,
    imageURL: URL? = nil,
    fontSize: Double = 64,
    fontName: String = "Helvetica Neue",
    fontWeight: CaptionFontWeight = .semibold,
    textAlignment: OverlayTextAlignment = .center,
    foregroundHex: String = "#FFFFFF",
    backgroundHex: String = "#00000099",
    strokeHex: String = "#000000FF",
    strokeWidth: Double = 0,
    textPadding: Double = 12,
    cornerRadius: Double = 8
  ) {
    self.id = id
    self.kind = kind
    self.startTime = startTime
    self.duration = duration
    self.normalizedX = normalizedX
    self.normalizedY = normalizedY
    self.normalizedWidth = normalizedWidth
    self.rotation = rotation
    self.opacity = opacity
    self.text = text
    self.imageURL = imageURL
    self.fontSize = fontSize
    self.fontName = fontName
    self.fontWeight = fontWeight
    self.textAlignment = textAlignment
    self.foregroundHex = foregroundHex
    self.backgroundHex = backgroundHex
    self.strokeHex = strokeHex
    self.strokeWidth = strokeWidth
    self.textPadding = textPadding
    self.cornerRadius = cornerRadius
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    kind = try values.decode(OverlayKind.self, forKey: .kind)
    startTime = try values.decode(Double.self, forKey: .startTime)
    duration = try values.decode(Double.self, forKey: .duration)
    normalizedX = try values.decodeIfPresent(Double.self, forKey: .normalizedX) ?? 0.5
    normalizedY = try values.decodeIfPresent(Double.self, forKey: .normalizedY) ?? 0.5
    normalizedWidth =
      try values.decodeIfPresent(Double.self, forKey: .normalizedWidth) ?? 0.5
    rotation = try values.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    text = try values.decodeIfPresent(String.self, forKey: .text)
    imageURL = try values.decodeIfPresent(URL.self, forKey: .imageURL)
    fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 64
    fontName =
      try values.decodeIfPresent(String.self, forKey: .fontName)
      ?? "Helvetica Neue"
    fontWeight =
      try values.decodeIfPresent(CaptionFontWeight.self, forKey: .fontWeight)
      ?? .semibold
    textAlignment =
      try values.decodeIfPresent(
        OverlayTextAlignment.self,
        forKey: .textAlignment
      ) ?? .center
    foregroundHex =
      try values.decodeIfPresent(String.self, forKey: .foregroundHex)
      ?? "#FFFFFF"
    backgroundHex =
      try values.decodeIfPresent(String.self, forKey: .backgroundHex)
      ?? "#00000099"
    strokeHex =
      try values.decodeIfPresent(String.self, forKey: .strokeHex)
      ?? "#000000FF"
    strokeWidth =
      try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
    textPadding =
      try values.decodeIfPresent(Double.self, forKey: .textPadding) ?? 12
    cornerRadius =
      try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 8
  }
}

extension Array where Element == OverlayItem {
  var inCompositingOrder: [OverlayItem] {
    enumerated()
      .sorted { lhs, rhs in
        let lhsRank = lhs.element.kind.compositingRank
        let rhsRank = rhs.element.kind.compositingRank
        return lhsRank == rhsRank
          ? lhs.offset < rhs.offset
          : lhsRank < rhsRank
      }
      .map(\.element)
  }
}

enum CaptionStylePreset: String, CaseIterable, Identifiable {
  case classic
  case accent
  case plain

  var id: String { rawValue }

  var title: String {
    switch self {
    case .classic: "Классический"
    case .accent: "Акцентный"
    case .plain: "Без подложки"
    }
  }

  var style: CaptionStyle {
    switch self {
    case .classic:
      CaptionStyle()
    case .accent:
      CaptionStyle(
        fontName: "Avenir Next",
        fontWeight: .heavy,
        foregroundHex: "#111111FF",
        backgroundHex: "#FFD60AFF",
        strokeHex: "#FFFFFFFF",
        strokeWidth: 0,
        textPadding: 15,
        cornerRadius: 12
      )
    case .plain:
      CaptionStyle(
        fontWeight: .bold,
        foregroundHex: "#FFFFFFFF",
        backgroundHex: "#00000000",
        strokeHex: "#000000FF",
        strokeWidth: 3,
        textPadding: 4,
        cornerRadius: 0
      )
    }
  }
}

struct CaptionStyle: Codable, Equatable {
  var normalizedX = 0.5
  var normalizedY = 0.84
  var normalizedWidth = 0.82
  var fontSize = 58.0
  var fontName = "Helvetica Neue"
  var fontWeight = CaptionFontWeight.semibold
  var textAlignment = OverlayTextAlignment.center
  var foregroundHex = "#FFFFFFFF"
  var backgroundHex = "#000000B3"
  var strokeHex = "#000000FF"
  var strokeWidth = 0.0
  var textPadding = 12.0
  var cornerRadius = 8.0

  enum CodingKeys: String, CodingKey {
    case normalizedX, normalizedY, normalizedWidth, fontSize, fontName
    case fontWeight, textAlignment, foregroundHex, backgroundHex
    case strokeHex, strokeWidth, textPadding, cornerRadius
  }

  init(
    normalizedX: Double = 0.5,
    normalizedY: Double = 0.84,
    normalizedWidth: Double = 0.82,
    fontSize: Double = 58,
    fontName: String = "Helvetica Neue",
    fontWeight: CaptionFontWeight = .semibold,
    textAlignment: OverlayTextAlignment = .center,
    foregroundHex: String = "#FFFFFFFF",
    backgroundHex: String = "#000000B3",
    strokeHex: String = "#000000FF",
    strokeWidth: Double = 0,
    textPadding: Double = 12,
    cornerRadius: Double = 8
  ) {
    self.normalizedX = normalizedX
    self.normalizedY = normalizedY
    self.normalizedWidth = normalizedWidth
    self.fontSize = fontSize
    self.fontName = fontName
    self.fontWeight = fontWeight
    self.textAlignment = textAlignment
    self.foregroundHex = foregroundHex
    self.backgroundHex = backgroundHex
    self.strokeHex = strokeHex
    self.strokeWidth = strokeWidth
    self.textPadding = textPadding
    self.cornerRadius = cornerRadius
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    normalizedX =
      try values.decodeIfPresent(Double.self, forKey: .normalizedX) ?? 0.5
    normalizedY =
      try values.decodeIfPresent(Double.self, forKey: .normalizedY) ?? 0.84
    normalizedWidth =
      try values.decodeIfPresent(Double.self, forKey: .normalizedWidth) ?? 0.82
    fontSize =
      try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 58
    fontName =
      try values.decodeIfPresent(String.self, forKey: .fontName)
      ?? "Helvetica Neue"
    fontWeight =
      try values.decodeIfPresent(CaptionFontWeight.self, forKey: .fontWeight)
      ?? .semibold
    textAlignment =
      try values.decodeIfPresent(
        OverlayTextAlignment.self,
        forKey: .textAlignment
      ) ?? .center
    foregroundHex =
      try values.decodeIfPresent(String.self, forKey: .foregroundHex)
      ?? "#FFFFFFFF"
    backgroundHex =
      try values.decodeIfPresent(String.self, forKey: .backgroundHex)
      ?? "#000000B3"
    strokeHex =
      try values.decodeIfPresent(String.self, forKey: .strokeHex)
      ?? "#000000FF"
    strokeWidth =
      try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
    textPadding =
      try values.decodeIfPresent(Double.self, forKey: .textPadding) ?? 12
    cornerRadius =
      try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 8
  }

  init(item: OverlayItem) {
    normalizedX = item.normalizedX
    normalizedY = item.normalizedY
    normalizedWidth = item.normalizedWidth
    fontSize = item.fontSize
    fontName = item.fontName
    fontWeight = item.fontWeight
    textAlignment = item.textAlignment
    foregroundHex = item.foregroundHex
    backgroundHex = item.backgroundHex
    strokeHex = item.strokeHex
    strokeWidth = item.strokeWidth
    textPadding = item.textPadding
    cornerRadius = item.cornerRadius
  }

  static func defaultStyle(for canvas: CanvasPreset) -> CaptionStyle {
    var style = CaptionStyle()
    if canvas == .vertical {
      style.normalizedY = 0.70
    }
    return style
  }

  func adaptingBuiltInPosition(to canvas: CanvasPreset) -> CaptionStyle {
    let isBuiltIn = CaptionStylePreset.allCases.contains { $0.style == self }
    guard isBuiltIn else { return self }
    var adapted = self
    adapted.normalizedY = CaptionStyle.defaultStyle(for: canvas).normalizedY
    return adapted
  }

  func apply(to item: inout OverlayItem) {
    item.normalizedX = normalizedX
    item.normalizedY = normalizedY
    item.normalizedWidth = normalizedWidth
    item.fontSize = fontSize
    item.fontName = fontName
    item.fontWeight = fontWeight
    item.textAlignment = textAlignment
    item.foregroundHex = foregroundHex
    item.backgroundHex = backgroundHex
    item.strokeHex = strokeHex
    item.strokeWidth = strokeWidth
    item.textPadding = textPadding
    item.cornerRadius = cornerRadius
  }
}

struct ProjectFile: Codable {
  var version = ProjectPackageService.currentVersion
  var name: String
  var canvas: CanvasPreset
  var scalingMode = VideoScalingMode.fit
  var clips: [VideoClip]
  var overlays: [OverlayItem]
  var audio = AudioSettings()
  var color = ColorSettings()

  enum CodingKeys: String, CodingKey {
    case version, name, canvas, scalingMode, clips, overlays, audio, color
  }

  init(
    version: Int = ProjectPackageService.currentVersion,
    name: String,
    canvas: CanvasPreset,
    scalingMode: VideoScalingMode = .fit,
    clips: [VideoClip],
    overlays: [OverlayItem],
    audio: AudioSettings = AudioSettings(),
    color: ColorSettings = ColorSettings()
  ) {
    self.version = version
    self.name = name
    self.canvas = canvas
    self.scalingMode = scalingMode
    self.clips = clips
    self.overlays = overlays
    self.audio = audio
    self.color = color
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
    name = try values.decode(String.self, forKey: .name)
    canvas = try values.decode(CanvasPreset.self, forKey: .canvas)
    scalingMode =
      try values.decodeIfPresent(VideoScalingMode.self, forKey: .scalingMode)
      ?? .fit
    clips = try values.decode([VideoClip].self, forKey: .clips)
    overlays = try values.decode([OverlayItem].self, forKey: .overlays)
    audio =
      try values.decodeIfPresent(AudioSettings.self, forKey: .audio)
      ?? AudioSettings()
    color =
      try values.decodeIfPresent(ColorSettings.self, forKey: .color)
      ?? ColorSettings()
  }
}

enum TrimEdge {
  case leading
  case trailing
}

struct TrimPreviewAdjustment: Equatable {
  let offset: CGFloat
  let width: CGFloat
}

enum TimelineInteractionGeometry {
  static func contentX(
    viewportX: CGFloat,
    contentMinX: CGFloat
  ) -> CGFloat {
    viewportX - contentMinX
  }

  static func time(
    at x: CGFloat,
    width: CGFloat,
    duration: Double
  ) -> Double {
    guard width > 0, duration > 0 else { return 0 }
    let ratio = min(1, max(0, x / width))
    return Double(ratio) * duration
  }

  static func snappedX(
    _ x: CGFloat,
    targetX: CGFloat,
    threshold: CGFloat
  ) -> CGFloat {
    abs(x - targetX) <= max(0, threshold) ? targetX : x
  }
}

enum TrimPreviewGeometry {
  static func adjustment(
    for clip: VideoClip,
    edge: TrimEdge,
    translation: CGFloat,
    pixelsPerSecond: Double
  ) -> TrimPreviewAdjustment {
    let scale = max(pixelsPerSecond, 0.01)
    let minimumDelta: CGFloat
    let maximumDelta: CGFloat
    switch edge {
    case .leading:
      minimumDelta = -clip.sourceStart * scale
      maximumDelta = max(0, clip.duration - 0.1) * scale
      let delta = min(max(translation, minimumDelta), maximumDelta)
      return TrimPreviewAdjustment(offset: delta, width: -delta)
    case .trailing:
      minimumDelta = -max(0, clip.duration - 0.1) * scale
      maximumDelta =
        max(
          0,
          (clip.sourceDuration ?? clip.sourceEnd) - clip.sourceEnd
        ) * scale
      let delta = min(max(translation, minimumDelta), maximumDelta)
      return TrimPreviewAdjustment(offset: 0, width: delta)
    }
  }
}

struct CaptionDraft: Equatable, Sendable {
  var text: String
  var startTime: Double
  var endTime: Double
}

struct CaptionWord: Equatable, Sendable {
  var text: String
  var startTime: Double
  var endTime: Double
}

extension Double {
  var timestamp: String {
    guard isFinite else { return "00:00.0" }
    let value = max(0, self)
    let minutes = Int(value) / 60
    let seconds = value - Double(minutes * 60)
    return String(format: "%02d:%04.1f", minutes, seconds)
  }
}
