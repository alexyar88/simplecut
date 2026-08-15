import AppKit

private final class CaptionRenderCacheEntry {
  let result: CaptionRenderResult

  init(_ result: CaptionRenderResult) {
    self.result = result
  }
}

private final class CaptionRenderCache: @unchecked Sendable {
  let storage: NSCache<NSString, CaptionRenderCacheEntry> = {
    let cache = NSCache<NSString, CaptionRenderCacheEntry>()
    cache.countLimit = 256
    cache.totalCostLimit = 192 * 1_024 * 1_024
    return cache
  }()
}

struct CaptionRenderResult {
  let image: CGImage
  let size: CGSize
}

enum CaptionRenderer {
  private static let cache = CaptionRenderCache()

  static func render(
    item: OverlayItem,
    canvasSize: CGSize
  ) -> CaptionRenderResult? {
    let cacheKey = renderCacheKey(item: item, canvasSize: canvasSize)
    if let cached = cache.storage.object(forKey: cacheKey) {
      return cached.result
    }
    let scale = canvasSize.width / 1_080
    let fontSize = max(1, item.fontSize * scale)
    let baseFont =
      NSFont(name: item.fontName, size: fontSize)
      ?? NSFont.systemFont(ofSize: fontSize)
    let font = NSFontManager.shared.convert(
      baseFont,
      toHaveTrait: item.fontWeight.fontTrait
    )
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = item.textAlignment.nsTextAlignment
    paragraph.lineBreakMode = .byWordWrapping
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor(hex: item.foregroundHex),
      .paragraphStyle: paragraph,
    ]
    let stroke = max(0, item.strokeWidth * scale)
    if stroke > 0 {
      attributes[.strokeColor] = NSColor(hex: item.strokeHex)
      attributes[.strokeWidth] = -100 * stroke / max(fontSize, 1)
    }

    let attributed = NSAttributedString(
      string: item.text ?? "",
      attributes: attributes
    )
    let width = max(1, canvasSize.width * item.normalizedWidth)
    let backgroundInset = item.backgroundEnabled
      ? max(0, item.textPadding * scale)
      : 0
    let inset = backgroundInset + stroke
    let textWidth = max(1, width - inset * 2)
    let measured = attributed.boundingRect(
      with: CGSize(
        width: textWidth,
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let textHeight = max(fontSize * 1.25, ceil(measured.height))
    let height = max(1, textHeight + inset * 2)
    let pixelsWide = max(1, Int(ceil(width)))
    let pixelsHigh = max(1, Int(ceil(height)))
    guard
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: representation)
    else {
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    let bounds = CGRect(
      x: 0,
      y: 0,
      width: pixelsWide,
      height: pixelsHigh
    )
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    if item.backgroundEnabled {
      NSColor(hex: item.backgroundHex).setFill()
      NSBezierPath(
        roundedRect: bounds,
        xRadius: max(0, item.cornerRadius * scale),
        yRadius: max(0, item.cornerRadius * scale)
      ).fill()
    }
    attributed.draw(
      with: CGRect(
        x: inset,
        y: inset,
        width: max(1, CGFloat(pixelsWide) - inset * 2),
        height: textHeight
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = representation.cgImage else { return nil }
    let result = CaptionRenderResult(
      image: image,
      size: CGSize(width: width, height: height)
    )
    cache.storage.setObject(
      CaptionRenderCacheEntry(result),
      forKey: cacheKey,
      cost: pixelsWide * pixelsHigh * 4
    )
    return result
  }

  private static func renderCacheKey(
    item: OverlayItem,
    canvasSize: CGSize
  ) -> NSString {
    let components: [String] = [
      item.id.uuidString,
      item.text ?? "",
      item.fontName,
      item.fontWeight.rawValue,
      item.textAlignment.rawValue,
      item.foregroundHex,
      String(item.backgroundEnabled),
      item.backgroundHex,
      item.strokeHex,
      String(item.fontSize),
      String(item.normalizedWidth),
      String(item.strokeWidth),
      String(item.textPadding),
      String(item.cornerRadius),
      String(Double(canvasSize.width)),
      String(Double(canvasSize.height)),
    ]
    return components.joined(separator: "|") as NSString
  }
}

extension OverlayTextAlignment {
  var nsTextAlignment: NSTextAlignment {
    switch self {
    case .left: .left
    case .center: .center
    case .right: .right
    }
  }
}

extension NSColor {
  convenience init(hex: String) {
    let value = hex.trimmingCharacters(
      in: CharacterSet.alphanumerics.inverted
    )
    var number: UInt64 = 0
    Scanner(string: value).scanHexInt64(&number)
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    switch value.count {
    case 8:
      red = CGFloat((number >> 24) & 0xFF) / 255
      green = CGFloat((number >> 16) & 0xFF) / 255
      blue = CGFloat((number >> 8) & 0xFF) / 255
      alpha = CGFloat(number & 0xFF) / 255
    default:
      red = CGFloat((number >> 16) & 0xFF) / 255
      green = CGFloat((number >> 8) & 0xFF) / 255
      blue = CGFloat(number & 0xFF) / 255
      alpha = 1
    }
    self.init(
      calibratedRed: red,
      green: green,
      blue: blue,
      alpha: alpha
    )
  }

  var simpleCutHex: String {
    let color = usingColorSpace(.deviceRGB) ?? self
    return String(
      format: "#%02X%02X%02X%02X",
      Int((color.redComponent * 255).rounded()),
      Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded()),
      Int((color.alphaComponent * 255).rounded())
    )
  }
}

extension CaptionFontWeight {
  var fontTrait: NSFontTraitMask {
    switch self {
    case .regular: []
    case .semibold, .bold: .boldFontMask
    case .heavy: [.boldFontMask, .expandedFontMask]
    }
  }
}
