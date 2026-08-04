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
  var version = 1
  var name: String
  var canvas: CanvasPreset
  var clips: [VideoClip]
  var overlays: [OverlayItem]
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
