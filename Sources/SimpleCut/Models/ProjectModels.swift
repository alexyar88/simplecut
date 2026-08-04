import CoreGraphics
import Foundation

enum CanvasPreset: String, Codable, CaseIterable, Identifiable {
  case vertical
  case horizontal
  case square

  var id: String { rawValue }

  var title: String {
    switch self {
    case .vertical: "9:16"
    case .horizontal: "16:9"
    case .square: "1:1"
    }
  }

  var size: CGSize {
    switch self {
    case .vertical: CGSize(width: 1080, height: 1920)
    case .horizontal: CGSize(width: 1920, height: 1080)
    case .square: CGSize(width: 1080, height: 1080)
    }
  }
}

struct VideoClip: Identifiable, Codable, Equatable {
  var id = UUID()
  var sourceURL: URL
  var sourceStart: Double
  var duration: Double

  var sourceEnd: Double { sourceStart + duration }
}

struct AudioSettings: Codable, Equatable {
  var normalizeLoudness = false
  var targetLUFS = -14.0
  var limiterEnabled = true
  var peakCeilingDB = -1.0
  var masterGainDB = 0.0
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
}

enum OverlayKind: String, Codable {
  case text
  case image
  case caption

  var isTextual: Bool {
    self != .image
  }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
  case base
  case accurate = "large-v3-v20240930_626MB"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .base: "Быстро · Base"
    case .accurate: "Точно · Large v3"
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
  var foregroundHex: String = "#FFFFFF"
  var backgroundHex: String = "#00000099"
}

struct ProjectFile: Codable {
  var version = ProjectPackageService.currentVersion
  var name: String
  var canvas: CanvasPreset
  var clips: [VideoClip]
  var overlays: [OverlayItem]
  var audio = AudioSettings()
  var color = ColorSettings()

  enum CodingKeys: String, CodingKey {
    case version, name, canvas, clips, overlays, audio, color
  }

  init(
    version: Int = ProjectPackageService.currentVersion,
    name: String,
    canvas: CanvasPreset,
    clips: [VideoClip],
    overlays: [OverlayItem],
    audio: AudioSettings = AudioSettings(),
    color: ColorSettings = ColorSettings()
  ) {
    self.version = version
    self.name = name
    self.canvas = canvas
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
