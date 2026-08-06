import Foundation

enum CaptionStyleStore {
  private enum Key {
    static let active = "SimpleCut.captionStyle.active"
    static let custom = "SimpleCut.captionStyle.custom"
  }

  static func activeStyle(in defaults: UserDefaults = .standard) -> CaptionStyle {
    decode(defaults.data(forKey: Key.active)) ?? .init()
  }

  static func customStyle(in defaults: UserDefaults = .standard) -> CaptionStyle? {
    decode(defaults.data(forKey: Key.custom))
  }

  static func select(
    preset: CaptionStylePreset,
    in defaults: UserDefaults = .standard
  ) {
    store(preset.style, forKey: Key.active, in: defaults)
  }

  static func selectCustom(in defaults: UserDefaults = .standard) {
    guard let style = customStyle(in: defaults) else { return }
    store(style, forKey: Key.active, in: defaults)
  }

  static func saveCustom(
    _ style: CaptionStyle,
    in defaults: UserDefaults = .standard
  ) {
    store(style, forKey: Key.custom, in: defaults)
    store(style, forKey: Key.active, in: defaults)
  }

  static func deleteCustom(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Key.custom)
    select(preset: .classic, in: defaults)
  }

  private static func store(
    _ style: CaptionStyle,
    forKey key: String,
    in defaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(style) else { return }
    defaults.set(data, forKey: key)
  }

  private static func decode(_ data: Data?) -> CaptionStyle? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(CaptionStyle.self, from: data)
  }
}
