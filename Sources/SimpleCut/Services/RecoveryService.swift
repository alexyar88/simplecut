import Foundation

enum RecoveryService {
  static func save(_ project: ProjectFile) throws {
    let destination = try recoveryURL()
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder.pretty.encode(project).write(
      to: destination,
      options: .atomic
    )
  }

  static func load() throws -> ProjectFile? {
    let destination = try recoveryURL()
    guard FileManager.default.fileExists(atPath: destination.path) else {
      return nil
    }
    return try JSONDecoder().decode(
      ProjectFile.self,
      from: Data(contentsOf: destination)
    )
  }

  static func clear() {
    guard let destination = try? recoveryURL() else { return }
    try? FileManager.default.removeItem(at: destination)
  }

  private static func recoveryURL() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("SimpleCut", isDirectory: true)
    .appendingPathComponent("Recovery", isDirectory: true)
    .appendingPathComponent("autosave.json")
  }
}
