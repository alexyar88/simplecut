import CoreGraphics
import XCTest

@testable import SimpleCut

final class ProjectModelsTests: XCTestCase {
  func testCanvasPresetsHaveExpectedOrientation() {
    XCTAssertGreaterThan(
      CanvasPreset.vertical.size.height,
      CanvasPreset.vertical.size.width
    )
    XCTAssertGreaterThan(
      CanvasPreset.horizontal.size.width,
      CanvasPreset.horizontal.size.height
    )
    XCTAssertEqual(
      CanvasPreset.square.size.width,
      CanvasPreset.square.size.height
    )
  }

  func testProjectRoundTripKeepsClipsAndOverlays() throws {
    let clip = VideoClip(
      sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
      sourceStart: 1.25,
      duration: 3.5
    )
    let overlay = OverlayItem(
      kind: .text,
      startTime: 0.5,
      duration: 2,
      text: "Заголовок"
    )
    let source = ProjectFile(
      name: "Тест",
      canvas: .vertical,
      clips: [clip],
      overlays: [overlay]
    )

    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode(ProjectFile.self, from: data)

    XCTAssertEqual(decoded.name, source.name)
    XCTAssertEqual(decoded.canvas, source.canvas)
    XCTAssertEqual(decoded.clips, source.clips)
    XCTAssertEqual(decoded.overlays, source.overlays)
  }

  func testCaptionGeneratorSplitsLongTextAndKeepsTiming() {
    let words = [
      CaptionWord(text: "Это", startTime: 0, endTime: 0.4),
      CaptionWord(text: "первая.", startTime: 0.4, endTime: 1),
      CaptionWord(text: "А", startTime: 1.2, endTime: 1.4),
      CaptionWord(text: "это", startTime: 1.4, endTime: 1.7),
      CaptionWord(text: "вторая", startTime: 1.7, endTime: 2.1),
      CaptionWord(text: "фраза.", startTime: 2.1, endTime: 2.8),
    ]

    let captions = CaptionGenerator.makeDrafts(words: words)

    XCTAssertEqual(captions.count, 2)
    XCTAssertEqual(captions[0].text, "Это первая.")
    XCTAssertEqual(captions[0].startTime, 0)
    XCTAssertEqual(captions[0].endTime, 1)
    XCTAssertEqual(captions[1].text, "А это вторая фраза.")
    XCTAssertEqual(captions[1].startTime, 1.2)
    XCTAssertEqual(captions[1].endTime, 2.8)
  }

  func testCaptureRotationAngles() {
    XCTAssertEqual(
      CaptureRotation.automatic.angle(automaticAngle: 42),
      42
    )
    XCTAssertEqual(CaptureRotation.none.angle(automaticAngle: 42), 0)
    XCTAssertEqual(
      CaptureRotation.clockwise90.angle(automaticAngle: 0),
      90
    )
    XCTAssertEqual(
      CaptureRotation.counterclockwise90.angle(automaticAngle: 0),
      270
    )
    XCTAssertEqual(
      CaptureRotation.upsideDown.angle(automaticAngle: 0),
      180
    )
  }

  func testImportedMediaGetsAStableUniqueCopy() throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCut-source-\(UUID().uuidString).mov")
    let contents = Data("video-placeholder".utf8)
    try contents.write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let first = try MediaLibrary.importVideo(from: source)
    let second = try MediaLibrary.importVideo(from: source)
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Data(contentsOf: first), contents)
    XCTAssertEqual(try Data(contentsOf: second), contents)
  }
}
