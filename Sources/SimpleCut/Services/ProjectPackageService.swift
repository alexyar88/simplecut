import Foundation

enum ProjectPackageService {
  static let currentVersion = 2
  static let packageExtension = "simplecut"
  static let manifestName = "project.json"
  private static let mediaScheme = "simplecut-media"

  static func canOpen(_ url: URL) -> Bool {
    let fileExtension = url.pathExtension.lowercased()
    return fileExtension == packageExtension || fileExtension == "json"
  }

  static func save(_ source: ProjectFile, to destination: URL) throws {
    let fileManager = FileManager.default
    let temporary = fileManager.temporaryDirectory
      .appendingPathComponent(".simplecut-\(UUID().uuidString)", isDirectory: true)
    let mediaDirectory = temporary.appendingPathComponent(
      "Media",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: mediaDirectory,
      withIntermediateDirectories: true
    )

    do {
      var stored = source
      stored.version = currentVersion
      var copiedFiles: [URL: URL] = [:]

      func packagedURL(for original: URL) throws -> URL {
        let canonical = original.standardizedFileURL
        if let existing = copiedFiles[canonical] {
          return existing
        }
        guard fileManager.fileExists(atPath: canonical.path) else {
          throw ProjectPackageError.missingMedia(canonical.lastPathComponent)
        }
        let suffix = canonical.pathExtension
        let fileName =
          suffix.isEmpty
          ? UUID().uuidString
          : "\(UUID().uuidString).\(suffix)"
        let copied = mediaDirectory.appendingPathComponent(fileName)
        try fileManager.copyItem(at: canonical, to: copied)
        guard let reference = URL(
          string: "\(mediaScheme):///\(fileName)"
        ) else {
          throw ProjectPackageError.invalidManifest
        }
        copiedFiles[canonical] = reference
        return reference
      }

      for index in stored.clips.indices {
        stored.clips[index].sourceURL = try packagedURL(
          for: stored.clips[index].sourceURL
        )
      }
      for index in stored.overlays.indices {
        if let imageURL = stored.overlays[index].imageURL {
          stored.overlays[index].imageURL = try packagedURL(for: imageURL)
        }
      }

      let manifest = try JSONEncoder.pretty.encode(stored)
      try manifest.write(
        to: temporary.appendingPathComponent(manifestName),
        options: .atomic
      )

      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
          destination,
          withItemAt: temporary,
          backupItemName: nil,
          options: []
        )
      } else {
        try fileManager.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }

  static func load(from source: URL) throws -> ProjectFile {
    let fileManager = FileManager.default
    let isPackage = source.pathExtension.lowercased() == packageExtension
      || (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let manifestURL =
      isPackage
      ? source.appendingPathComponent(manifestName)
      : source
    let data = try Data(contentsOf: manifestURL)
    var project: ProjectFile
    do {
      project = try JSONDecoder().decode(ProjectFile.self, from: data)
    } catch {
      throw ProjectPackageError.invalidManifest
    }
    guard project.version <= currentVersion else {
      throw ProjectPackageError.unsupportedVersion(project.version)
    }

    if isPackage {
      let mediaDirectory = source.appendingPathComponent("Media", isDirectory: true)

      func resolvedURL(_ stored: URL) throws -> URL {
        guard stored.scheme == mediaScheme else { return stored }
        let resolved = mediaDirectory.appendingPathComponent(
          stored.lastPathComponent
        )
        guard fileManager.fileExists(atPath: resolved.path) else {
          throw ProjectPackageError.missingMedia(stored.lastPathComponent)
        }
        return resolved
      }

      for index in project.clips.indices {
        project.clips[index].sourceURL = try resolvedURL(
          project.clips[index].sourceURL
        )
      }
      for index in project.overlays.indices {
        if let imageURL = project.overlays[index].imageURL {
          project.overlays[index].imageURL = try resolvedURL(imageURL)
        }
      }
    }

    for clip in project.clips
    where !fileManager.fileExists(atPath: clip.sourceURL.path) {
      throw ProjectPackageError.missingMedia(clip.sourceURL.lastPathComponent)
    }
    return project
  }
}

enum ProjectPackageError: LocalizedError {
  case invalidManifest
  case unsupportedVersion(Int)
  case missingMedia(String)
  case unsupportedFileType

  var errorDescription: String? {
    switch self {
    case .invalidManifest:
      "Файл проекта повреждён или имеет неизвестный формат"
    case .unsupportedVersion(let version):
      "Проект создан более новой версией SimpleCut (формат \(version))"
    case .missingMedia(let name):
      "В проекте отсутствует медиафайл: \(name)"
    case .unsupportedFileType:
      "Выберите проект SimpleCut (.simplecut) или совместимый JSON-файл"
    }
  }
}
