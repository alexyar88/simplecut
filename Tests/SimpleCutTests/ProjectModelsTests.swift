import CoreGraphics
import XCTest

@testable import SimpleCut

final class ProjectModelsTests: XCTestCase {
  func testWaveformNormalizationRaisesVisibleLevelAndMarksLimiter() {
    let waveform: [Float] = [0.08, 0.2, 0.5]
    let original = WaveformPresentation.samples(
      from: waveform,
      settings: AudioSettings(normalizeLoudness: false)
    )
    let normalized = WaveformPresentation.samples(
      from: waveform,
      settings: AudioSettings(normalizeLoudness: true)
    )

    XCTAssertGreaterThan(normalized[0].level, original[0].level)
    XCTAssertGreaterThan(normalized[1].level, original[1].level)
    XCTAssertTrue(normalized[2].reachesLimiter)
    XCTAssertLessThanOrEqual(
      normalized[2].level,
      Float(pow(10, -1.0 / 20)) + 0.0001
    )
  }

  func testWaveformNormalizationMarksPreLimiterClipping() {
    let normalized = WaveformPresentation.samples(
      from: [0.05, 0.12, 0.9],
      settings: AudioSettings(normalizeLoudness: true)
    )

    XCTAssertTrue(normalized[2].reachesLimiter)
    XCTAssertTrue(normalized[2].clipsWithoutLimiter)
  }

  func testDisabledNormalizationKeepsOriginalWaveformShape() {
    let waveform: [Float] = [0.2, 0.91, 1]
    let displayed = WaveformPresentation.samples(
      from: waveform,
      settings: AudioSettings(normalizeLoudness: false)
    )

    XCTAssertEqual(displayed.map(\.level), waveform)
    XCTAssertFalse(displayed.contains(where: \.reachesLimiter))
    XCTAssertFalse(displayed.contains(where: \.clipsWithoutLimiter))
  }

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
      scalingMode: .fill,
      clips: [clip],
      overlays: [overlay],
      audio: AudioSettings(normalizeLoudness: true),
      color: .automatic
    )

    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode(ProjectFile.self, from: data)

    XCTAssertEqual(decoded.name, source.name)
    XCTAssertEqual(decoded.canvas, source.canvas)
    XCTAssertEqual(decoded.scalingMode, source.scalingMode)
    XCTAssertEqual(decoded.clips, source.clips)
    XCTAssertEqual(decoded.overlays, source.overlays)
    XCTAssertEqual(decoded.audio, source.audio)
    XCTAssertEqual(decoded.color, source.color)
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
    XCTAssertEqual(CaptureRotation.none.rotatedClockwise, .clockwise90)
    XCTAssertEqual(CaptureRotation.clockwise90.rotatedClockwise, .upsideDown)
    XCTAssertEqual(
      CaptureRotation.upsideDown.rotatedClockwise,
      .counterclockwise90
    )
    XCTAssertEqual(CaptureRotation.counterclockwise90.rotatedClockwise, .none)
    XCTAssertEqual(
      CaptureRotation.none.rotatedCounterclockwise,
      .counterclockwise90
    )
    XCTAssertEqual(
      CaptureRotation.counterclockwise90.rotatedCounterclockwise,
      .upsideDown
    )
    XCTAssertEqual(
      CaptureRotation.upsideDown.rotatedCounterclockwise,
      .clockwise90
    )
    XCTAssertEqual(
      CaptureRotation.clockwise90.rotatedCounterclockwise,
      .none
    )
    XCTAssertEqual(
      CaptureRotation.none.connectionAngle(
        automaticAngle: 0,
        mirrored: true
      ),
      0
    )
    XCTAssertEqual(
      CaptureRotation.clockwise90.connectionAngle(
        automaticAngle: 0,
        mirrored: true
      ),
      270
    )
    XCTAssertEqual(
      CaptureRotation.counterclockwise90.connectionAngle(
        automaticAngle: 0,
        mirrored: true
      ),
      90
    )
    XCTAssertEqual(
      CaptureRotation.upsideDown.connectionAngle(
        automaticAngle: 0,
        mirrored: true
      ),
      180
    )
  }

  @MainActor
  func testSplitAndDeleteKeepTimelineRippleClosed() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 6
      )
    ]

    project.seek(to: 2)
    project.splitAtPlayhead()

    XCTAssertEqual(project.clips.map(\.duration), [2, 4])
    XCTAssertEqual(project.clips[0].sourceEnd, project.clips[1].sourceStart)
    XCTAssertEqual(project.duration, 6)

    project.seek(to: 5)
    project.selectedClipID = project.clips[0].id
    project.deleteSelectedClip()

    XCTAssertEqual(project.clips.count, 1)
    XCTAssertEqual(project.duration, 4)
    XCTAssertEqual(project.playhead, 3)
  }

  @MainActor
  func testSplitAvailabilityExcludesClipBoundaries() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 3
      ),
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 3,
        duration: 2
      ),
    ]

    project.seek(to: 0)
    XCTAssertFalse(project.canSplitAtPlayhead)
    project.seek(to: 1.5)
    XCTAssertTrue(project.canSplitAtPlayhead)
    project.seek(to: 3)
    XCTAssertFalse(project.canSplitAtPlayhead)
    project.seek(to: 4)
    XCTAssertTrue(project.canSplitAtPlayhead)
    project.seek(to: 5)
    XCTAssertFalse(project.canSplitAtPlayhead)
  }

  @MainActor
  func testJoiningSelectedSplitClipsRestoresSingleClip() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    project.clips = [
      VideoClip(
        sourceURL: source,
        sourceStart: 0,
        duration: 6,
        sourceDuration: 6
      )
    ]
    project.seek(to: 2)
    project.splitAtPlayhead()
    project.selectClip(id: project.clips[0].id)
    project.selectClip(id: project.clips[1].id, extending: true)

    XCTAssertTrue(project.canJoinSelectedClips)
    project.joinSelectedClips()

    XCTAssertEqual(project.clips.count, 1)
    XCTAssertEqual(project.clips[0].sourceStart, 0)
    XCTAssertEqual(project.clips[0].duration, 6)
    XCTAssertEqual(project.selectedClipIDs, [project.clips[0].id])
  }

  @MainActor
  func testJoiningRejectsNonContiguousSourceRanges() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    project.clips = [
      VideoClip(sourceURL: source, sourceStart: 0, duration: 1),
      VideoClip(sourceURL: source, sourceStart: 2, duration: 1),
    ]
    project.selectAllClips()

    XCTAssertFalse(project.canJoinSelectedClips)
    project.joinSelectedClips()

    XCTAssertEqual(project.clips.count, 2)
  }

  func testExportSummaryUsesCanvasResolutionAndDuration() {
    let settings = ExportSettings(
      quality: .compatible,
      resolution: .small,
      framesPerSecond: 30
    )

    XCTAssertEqual(
      settings.outputSize(for: .vertical),
      CGSize(width: 720, height: 1280)
    )
    XCTAssertTrue(settings.estimatedFileSize(duration: 60).contains("МБ"))
  }

  @MainActor
  func testRollingTrimMovesSplitBoundaryInBothDirections() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    project.clips = [
      VideoClip(sourceURL: source, sourceStart: 0, duration: 2),
      VideoClip(sourceURL: source, sourceStart: 2, duration: 4),
    ]

    XCTAssertTrue(project.canRollEdit(atBoundary: 1))
    XCTAssertTrue(project.rollEdit(atBoundary: 1, by: 1))
    XCTAssertEqual(project.clips.map(\.duration), [3, 3])
    XCTAssertEqual(project.clips[1].sourceStart, 3)
    XCTAssertEqual(project.duration, 6)

    XCTAssertTrue(project.rollEdit(atBoundary: 1, by: -2))
    XCTAssertEqual(project.clips.map(\.duration), [1, 5])
    XCTAssertEqual(project.clips[1].sourceStart, 1)
    XCTAssertEqual(project.duration, 6)
    XCTAssertEqual(project.clips[0].sourceEnd, project.clips[1].sourceStart)
  }

  @MainActor
  func testClipSelectionSupportsToggleRangeAndSelectAll() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    project.clips = (0..<4).map { index in
      VideoClip(
        sourceURL: source,
        sourceStart: Double(index),
        duration: 1,
        sourceDuration: 4
      )
    }

    project.selectClip(id: project.clips[0].id)
    project.selectClip(id: project.clips[2].id, range: true)
    XCTAssertEqual(
      project.selectedClipIDs,
      Set(project.clips[0...2].map(\.id))
    )

    project.selectClip(id: project.clips[1].id, extending: true)
    XCTAssertEqual(
      project.selectedClipIDs,
      Set([project.clips[0].id, project.clips[2].id])
    )

    project.selectAllClips()
    XCTAssertEqual(project.selectedClipIDs, Set(project.clips.map(\.id)))

    project.clearClipSelection()
    XCTAssertTrue(project.selectedClipIDs.isEmpty)
    XCTAssertNil(project.selectedClipID)
  }

  @MainActor
  func testDeletingMultipleSelectedClipsRipplesTimelineOnce() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    project.clips = (0..<4).map { index in
      VideoClip(
        sourceURL: source,
        sourceStart: Double(index),
        duration: 1,
        sourceDuration: 4
      )
    }
    let removedIDs = [project.clips[1].id, project.clips[2].id]
    project.seek(to: 3.5)
    project.selectClip(id: removedIDs[0])
    project.selectClip(id: removedIDs[1], extending: true)

    project.deleteSelectedClips()

    XCTAssertEqual(project.clips.count, 2)
    XCTAssertFalse(project.clips.contains { removedIDs.contains($0.id) })
    XCTAssertEqual(project.duration, 2)
    XCTAssertEqual(project.playhead, 1.5)
  }

  @MainActor
  func testClipEdgesCanShrinkAndRestoreAvailableSource() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    let clip = VideoClip(
      sourceURL: source,
      sourceStart: 2,
      duration: 4,
      sourceDuration: 10
    )
    project.clips = [clip]

    project.resizeClip(id: clip.id, edge: .leading, by: -1)
    XCTAssertEqual(project.clips[0].sourceStart, 1)
    XCTAssertEqual(project.clips[0].duration, 5)

    project.resizeClip(id: clip.id, edge: .trailing, by: 2)
    XCTAssertEqual(project.clips[0].duration, 7)
    XCTAssertEqual(project.clips[0].sourceEnd, 8)

    project.resizeClip(id: clip.id, edge: .trailing, by: -3)
    XCTAssertEqual(project.clips[0].duration, 4)
    XCTAssertEqual(project.clips[0].sourceEnd, 5)
  }

  @MainActor
  func testTrimmingLeadingEdgeOfSplitClipDoesNotResizePreviousClip() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    project.clips = [
      VideoClip(
        sourceURL: source,
        sourceStart: 0,
        duration: 7.5,
        sourceDuration: 10.5
      ),
      VideoClip(
        sourceURL: source,
        sourceStart: 7.5,
        duration: 3,
        sourceDuration: 10.5
      ),
    ]
    let firstClip = project.clips[0]
    let secondClipID = project.clips[1].id

    project.resizeClip(id: secondClipID, edge: .leading, by: 1)

    XCTAssertEqual(project.clips[0], firstClip)
    XCTAssertEqual(project.clips[1].sourceStart, 8.5)
    XCTAssertEqual(project.clips[1].duration, 2)
    XCTAssertEqual(project.duration, 9.5)
    XCTAssertEqual(project.selectedClipID, secondClipID)
  }

  @MainActor
  func testRelativeSeekingClampsToTimelineBounds() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 2
      )
    ]

    project.seek(to: 1)
    project.seek(by: -1.0 / 30)
    XCTAssertEqual(project.playhead, 29.0 / 30, accuracy: 0.0001)

    project.seek(by: -10)
    XCTAssertEqual(project.playhead, 0)

    project.seek(by: 10)
    XCTAssertEqual(project.playhead, 2)

    project.timelineZoom = 1
    XCTAssertEqual(project.timelineNavigationStep, 1.0 / 30)
    project.timelineZoom = 5
    XCTAssertEqual(project.timelineNavigationStep, 1.0 / 150)
  }

  @MainActor
  func testTextAddedAtTimelineEndStaysInsideProject() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 10
      )
    ]

    project.seek(to: project.duration)
    project.addText()

    let overlay = try! XCTUnwrap(project.overlays.first)
    XCTAssertEqual(overlay.startTime, 9.9, accuracy: 0.0001)
    XCTAssertEqual(overlay.duration, 0.1, accuracy: 0.0001)
    XCTAssertEqual(overlay.startTime + overlay.duration, project.duration)
  }

  @MainActor
  func testCaptionDraftsAreClampedToProjectDuration() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]

    let captions = project.replaceCaptions(with: [
      CaptionDraft(text: "before", startTime: -1, endTime: 1),
      CaptionDraft(text: "inside", startTime: 4, endTime: 7),
      CaptionDraft(text: "outside", startTime: 8, endTime: 9),
    ])

    XCTAssertEqual(captions.count, 2)
    XCTAssertEqual(captions[0].startTime, 0)
    XCTAssertEqual(captions[0].duration, 1)
    XCTAssertEqual(captions[1].startTime, 4)
    XCTAssertEqual(captions[1].duration, 1)
    XCTAssertEqual(project.playhead, 0)
    XCTAssertEqual(project.selectedOverlayID, captions[0].id)
  }

  @MainActor
  func testUndoRestoresEditingContext() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 10
      )
    ]
    project.seek(to: 4)
    project.addText()
    let overlayID = try! XCTUnwrap(project.overlays.first?.id)
    project.timelineZoom = 3
    project.recordUndoCheckpoint()
    project.overlays[0].text = "Changed"
    project.selectedOverlayID = nil
    project.selectClip(id: project.clips[0].id)
    project.seek(to: 8)
    project.timelineZoom = 1

    project.undo()

    XCTAssertEqual(project.selectedOverlayID, overlayID)
    XCTAssertTrue(project.selectedClipIDs.isEmpty)
    XCTAssertEqual(project.playhead, 4)
    XCTAssertEqual(project.timelineZoom, 3)
  }

  @MainActor
  func testOverlayTimingCanMoveAndResizeWithinProject() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 10
      )
    ]
    project.seek(to: 8)
    project.addText()
    let overlayID = try! XCTUnwrap(project.overlays.first?.id)

    XCTAssertEqual(project.overlays[0].startTime, 8)
    XCTAssertEqual(project.overlays[0].duration, 2)

    project.moveOverlay(id: overlayID, by: -3)
    project.resizeOverlay(id: overlayID, edge: .leading, by: 1)
    project.resizeOverlay(id: overlayID, edge: .trailing, by: 2)

    XCTAssertEqual(project.overlays[0].startTime, 6)
    XCTAssertEqual(project.overlays[0].duration, 3)
    XCTAssertEqual(
      project.overlays[0].startTime + project.overlays[0].duration,
      9
    )
  }

  @MainActor
  func testNewProjectClearsUndoHistory() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 3
      )
    ]
    project.addText()
    XCTAssertTrue(project.canUndo)

    project.reset()

    XCTAssertFalse(project.canUndo)
    XCTAssertFalse(project.canRedo)
    XCTAssertFalse(project.isDirty)
    XCTAssertTrue(project.clips.isEmpty)
    XCTAssertTrue(project.overlays.isEmpty)
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

  func testPortableProjectPackageCopiesAndResolvesMedia() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCutPackage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mov")
    let image = root.appendingPathComponent("overlay.png")
    try Data("video".utf8).write(to: source)
    try Data("image".utf8).write(to: image)
    let destination = root.appendingPathComponent("Portable.simplecut")
    let project = ProjectFile(
      name: "Portable",
      canvas: .horizontal,
      clips: [
        VideoClip(sourceURL: source, sourceStart: 0, duration: 1)
      ],
      overlays: [
        OverlayItem(
          kind: .image,
          startTime: 0,
          duration: 1,
          imageURL: image
        )
      ]
    )

    try ProjectPackageService.save(project, to: destination)
    let manifest = try String(
      contentsOf: destination.appendingPathComponent("project.json"),
      encoding: .utf8
    )
    XCTAssertFalse(manifest.contains(root.path))

    let loaded = try ProjectPackageService.load(from: destination)
    XCTAssertEqual(loaded.version, ProjectPackageService.currentVersion)
    XCTAssertEqual(try Data(contentsOf: loaded.clips[0].sourceURL), Data("video".utf8))
    XCTAssertEqual(
      try Data(contentsOf: try XCTUnwrap(loaded.overlays[0].imageURL)),
      Data("image".utf8)
    )

    var updated = project
    updated.name = "Updated"
    try ProjectPackageService.save(updated, to: destination)
    XCTAssertEqual(
      try ProjectPackageService.load(from: destination).name,
      "Updated"
    )
  }

  @MainActor
  func testOpeningLegacyProjectClampsOverlayTiming() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SimpleCutLegacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mov")
    try Data("video".utf8).write(to: source)
    let destination = root.appendingPathComponent("Legacy.simplecut")
    try ProjectPackageService.save(
      ProjectFile(
        name: "Legacy",
        canvas: .vertical,
        clips: [
          VideoClip(sourceURL: source, sourceStart: 0, duration: 5)
        ],
        overlays: [
          OverlayItem(
            kind: .caption,
            startTime: 34.7,
            duration: 1.4,
            text: "Late caption"
          )
        ]
      ),
      to: destination
    )

    let project = EditorProject(loadRecovery: false)
    try project.loadProject(from: destination)

    XCTAssertEqual(project.overlays.count, 1)
    XCTAssertEqual(project.overlays[0].startTime, 4.9, accuracy: 0.0001)
    XCTAssertEqual(project.overlays[0].duration, 0.1, accuracy: 0.0001)
  }
}
