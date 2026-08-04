import Foundation

enum MediaLibrary {
  static func importVideo(from source: URL) throws -> URL {
    try importMedia(from: source, defaultExtension: "mov")
  }

  static func importImage(from source: URL) throws -> URL {
    try importMedia(from: source, defaultExtension: "png")
  }

  private static func importMedia(
    from source: URL,
    defaultExtension: String
  ) throws -> URL {
    let fileManager = FileManager.default
    let root = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("SimpleCut", isDirectory: true)
    .appendingPathComponent("Media", isDirectory: true)
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )

    let fileExtension = source.pathExtension.isEmpty
      ? defaultExtension
      : source.pathExtension
    let destination = root
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)
    try fileManager.copyItem(at: source, to: destination)
    return destination
  }
}
