import Foundation

enum MediaLibrary {
  static func recordingDestination() throws -> URL {
    try mediaRoot()
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mov")
  }

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
    let root = try mediaRoot()

    let fileExtension = source.pathExtension.isEmpty
      ? defaultExtension
      : source.pathExtension
    let destination = root
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)
    try fileManager.copyItem(at: source, to: destination)
    return destination
  }

  private static func mediaRoot() throws -> URL {
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
    return root
  }
}
