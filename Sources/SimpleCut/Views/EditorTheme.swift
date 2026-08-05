import SwiftUI

enum EditorTheme {
  static let canvas = Color(
    .sRGB,
    red: 0.055,
    green: 0.059,
    blue: 0.071,
    opacity: 1
  )
  static let panel = Color(
    .sRGB,
    red: 0.095,
    green: 0.102,
    blue: 0.118,
    opacity: 1
  )
  static let raised = Color(
    .sRGB,
    red: 0.137,
    green: 0.145,
    blue: 0.165,
    opacity: 1
  )
  static let timeline = Color(
    .sRGB,
    red: 0.070,
    green: 0.074,
    blue: 0.086,
    opacity: 1
  )
  static let separator = Color.white.opacity(0.14)
  static let accent = Color(
    .sRGB,
    red: 0.04,
    green: 0.52,
    blue: 1,
    opacity: 1
  )
  static let selection = Color(
    .sRGB,
    red: 1,
    green: 0.78,
    blue: 0.08,
    opacity: 1
  )
  static let trimPreview = Color(
    .sRGB,
    red: 1,
    green: 0.48,
    blue: 0.08,
    opacity: 1
  )
  static let audioBackground = Color(
    .sRGB,
    red: 0.075,
    green: 0.19,
    blue: 0.12,
    opacity: 1
  )
  static let audioBackgroundSelected = Color(
    .sRGB,
    red: 0.09,
    green: 0.27,
    blue: 0.16,
    opacity: 1
  )
  static let audioWave = Color(
    .sRGB,
    red: 0.30,
    green: 0.72,
    blue: 0.38,
    opacity: 1
  )
  static let audioWarning = Color(
    .sRGB,
    red: 1,
    green: 0.72,
    blue: 0.16,
    opacity: 1
  )
  static let audioClipping = Color(
    .sRGB,
    red: 1,
    green: 0.27,
    blue: 0.23,
    opacity: 1
  )
}
