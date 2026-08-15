import AppKit

@MainActor
enum PreviewAssetCache {
  private static let images: NSCache<NSURL, NSImage> = {
    let cache = NSCache<NSURL, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  static func image(at url: URL) -> NSImage? {
    let key = url as NSURL
    if let image = images.object(forKey: key) {
      return image
    }
    guard let image = NSImage(contentsOf: url) else { return nil }
    images.setObject(image, forKey: key)
    return image
  }
}
