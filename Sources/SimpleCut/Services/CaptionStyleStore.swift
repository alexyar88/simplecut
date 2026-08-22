import Foundation

struct NamedOverlayStyle: Codable, Equatable, Identifiable {
  var name: String
  var style: CaptionStyle

  var id: String { name }
}

enum CaptionStyleStore {
  private enum Key {
    static let active = "SimpleCut.captionStyle.active"
    static let activeText = "SimpleCut.textStyle.active"
    static let custom = "SimpleCut.captionStyle.custom"
    static let captionStyles = "SimpleCut.captionStyle.named.caption"
    static let textStyles = "SimpleCut.captionStyle.named.text"
  }

  static func activeStyle(in defaults: UserDefaults = .standard) -> CaptionStyle {
    activeStyle(for: .caption, in: defaults)
  }

  static func activeStyle(
    for kind: OverlayKind,
    in defaults: UserDefaults = .standard
  ) -> CaptionStyle {
    guard kind == .caption || kind == .text else { return .init() }
    return decode(defaults.data(forKey: activeStyleKey(for: kind)))
      ?? CaptionStyle.defaultStyle(for: kind)
  }

  static func customStyle(in defaults: UserDefaults = .standard) -> CaptionStyle? {
    decode(defaults.data(forKey: Key.custom))
  }

  static func namedStyles(
    for kind: OverlayKind,
    in defaults: UserDefaults = .standard
  ) -> [NamedOverlayStyle] {
    guard kind == .caption || kind == .text else { return [] }
    let key = namedStylesKey(for: kind)
    if let data = defaults.data(forKey: key),
      let styles = try? JSONDecoder().decode(
        [NamedOverlayStyle].self,
        from: data
      )
    {
      return styles
    }
    guard kind == .caption, let legacy = customStyle(in: defaults) else {
      return []
    }
    let migrated = [NamedOverlayStyle(name: "Мой стиль", style: legacy)]
    storeNamedStyles(migrated, for: kind, in: defaults)
    return migrated
  }

  static func saveNamed(
    _ style: CaptionStyle,
    name: String,
    for kind: OverlayKind,
    in defaults: UserDefaults = .standard
  ) {
    guard kind == .caption || kind == .text else { return }
    let normalizedName = name.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalizedName.isEmpty else { return }
    var styles = namedStyles(for: kind, in: defaults)
    if let index = styles.firstIndex(where: {
      $0.name.compare(
        normalizedName,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) == .orderedSame
    }) {
      styles[index] = NamedOverlayStyle(
        name: normalizedName,
        style: style
      )
    } else {
      styles.append(
        NamedOverlayStyle(name: normalizedName, style: style)
      )
    }
    storeNamedStyles(styles, for: kind, in: defaults)
  }

  static func deleteNamed(
    name: String,
    for kind: OverlayKind,
    in defaults: UserDefaults = .standard
  ) {
    var styles = namedStyles(for: kind, in: defaults)
    styles.removeAll { $0.name == name }
    storeNamedStyles(styles, for: kind, in: defaults)
    if kind == .caption, name == "Мой стиль" {
      defaults.removeObject(forKey: Key.custom)
    }
  }

  static func deleteAllNamed(
    for kind: OverlayKind,
    in defaults: UserDefaults = .standard
  ) {
    defaults.removeObject(forKey: namedStylesKey(for: kind))
    if kind == .caption {
      defaults.removeObject(forKey: Key.custom)
    }
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

  static func select(
    style: CaptionStyle,
    for kind: OverlayKind = .caption,
    in defaults: UserDefaults = .standard
  ) {
    guard kind == .caption || kind == .text else { return }
    store(style, forKey: activeStyleKey(for: kind), in: defaults)
  }

  static func saveCustom(
    _ style: CaptionStyle,
    in defaults: UserDefaults = .standard
  ) {
    store(style, forKey: Key.custom, in: defaults)
    store(style, forKey: Key.active, in: defaults)
    saveNamed(
      style,
      name: "Мой стиль",
      for: .caption,
      in: defaults
    )
  }

  static func deleteCustom(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: Key.custom)
    deleteNamed(name: "Мой стиль", for: .caption, in: defaults)
    select(preset: .classic, in: defaults)
  }

  private static func namedStylesKey(for kind: OverlayKind) -> String {
    kind == .text ? Key.textStyles : Key.captionStyles
  }

  private static func activeStyleKey(for kind: OverlayKind) -> String {
    kind == .text ? Key.activeText : Key.active
  }

  private static func storeNamedStyles(
    _ styles: [NamedOverlayStyle],
    for kind: OverlayKind,
    in defaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(styles) else { return }
    defaults.set(data, forKey: namedStylesKey(for: kind))
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
