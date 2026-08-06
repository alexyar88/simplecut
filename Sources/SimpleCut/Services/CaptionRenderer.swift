import AppKit

struct CaptionRenderResult {
  let image: CGImage
  let size: CGSize
}

enum CaptionRenderer {
  static func render(
    item: OverlayItem,
    canvasSize: CGSize
  ) -> CaptionRenderResult? {
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
    paragraph.alignment = .center
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
    let inset = max(0, item.textPadding * scale) + stroke
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
    NSColor(hex: item.backgroundHex).setFill()
    NSBezierPath(
      roundedRect: bounds,
      xRadius: max(0, item.cornerRadius * scale),
      yRadius: max(0, item.cornerRadius * scale)
    ).fill()
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
    return CaptionRenderResult(
      image: image,
      size: CGSize(width: width, height: height)
    )
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
