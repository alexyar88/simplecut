import AVFoundation
import Combine
import CoreGraphics
import XCTest

@testable import SimpleCut

final class ProjectModelsTests: XCTestCase {
  func testPreviewSizesAreReducedAndKeepCanvasAspectRatio() {
    XCTAssertEqual(CanvasPreset.vertical.previewSize, CGSize(width: 540, height: 960))
    XCTAssertEqual(CanvasPreset.horizontal.previewSize, CGSize(width: 960, height: 540))
    XCTAssertEqual(CanvasPreset.square.previewSize, CGSize(width: 960, height: 960))
  }

  func testTimelineInteractionMapsAndClampsTheWholeTrack() {
    XCTAssertEqual(
      TimelineInteractionGeometry.contentX(
        viewportX: 140,
        contentMinX: -320
      ),
      460
    )
    XCTAssertEqual(
      TimelineInteractionGeometry.time(at: -20, width: 400, duration: 10),
      0
    )
    XCTAssertEqual(
      TimelineInteractionGeometry.time(at: 100, width: 400, duration: 10),
      2.5
    )
    XCTAssertEqual(
      TimelineInteractionGeometry.time(at: 600, width: 400, duration: 10),
      10
    )
    XCTAssertEqual(
      TimelineInteractionGeometry.snappedX(104, targetX: 110, threshold: 7),
      110
    )
    XCTAssertEqual(
      TimelineInteractionGeometry.snappedX(102, targetX: 110, threshold: 7),
      102
    )
  }

  func testTimelineReorderGeometryUsesClipMidpointsAndIgnoresNoOpDrops() {
    let durations = [2.0, 4.0, 1.0]

    XCTAssertEqual(
      TimelineReorderGeometry.insertionIndex(
        at: 5,
        width: 700,
        clipDurations: durations
      ),
      0
    )
    XCTAssertEqual(
      TimelineReorderGeometry.insertionIndex(
        at: 300,
        width: 700,
        clipDurations: durations
      ),
      1
    )
    XCTAssertEqual(
      TimelineReorderGeometry.insertionIndex(
        at: 690,
        width: 700,
        clipDurations: durations
      ),
      3
    )
    XCTAssertNil(
      TimelineReorderGeometry.destinationIndex(
        sourceIndex: 1,
        insertionIndex: 2,
        clipCount: 3
      )
    )
    XCTAssertEqual(
      TimelineReorderGeometry.destinationIndex(
        sourceIndex: 0,
        insertionIndex: 3,
        clipCount: 3
      ),
      2
    )
  }

  @MainActor
  func testSkimmingKeepsAnchoredPlayheadUntilPositionIsCommitted() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/skimming-state.mov"),
        sourceStart: 0,
        duration: 6
      )
    ]

    project.seek(to: 2)
    project.scrub(to: 4)

    XCTAssertEqual(project.playhead, 4)
    XCTAssertEqual(project.playback.anchoredPlayhead, 2)

    project.seek(to: 3)

    XCTAssertEqual(project.playhead, 3)
    XCTAssertEqual(project.playback.anchoredPlayhead, 3)
  }

  @MainActor
  func testPlayheadUpdatesDoNotInvalidateWholeProject() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/playback-state.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    var projectUpdates = 0
    var playbackUpdates = 0
    let projectObserver = project.objectWillChange.sink {
      projectUpdates += 1
    }
    let playbackObserver = project.playback.objectWillChange.sink {
      playbackUpdates += 1
    }

    project.seek(to: 2)

    XCTAssertEqual(project.playhead, 2)
    XCTAssertEqual(projectUpdates, 0)
    XCTAssertGreaterThan(playbackUpdates, 0)
    withExtendedLifetime((projectObserver, playbackObserver)) {}
  }

  func testWaveformPeakResamplingKeepsTransientsAndSilence() {
    let resampled = WaveformPresentation.peakResampled(
      [0, 0, 0.9, 0, 0, 0, 0.4, 0],
      targetSampleCount: 4
    )

    XCTAssertEqual(resampled, [0, 0.9, 0, 0.4])
  }

  func testWaveformRemappingFollowsTrimAndReorderImmediately() {
    let source = URL(fileURLWithPath: "/tmp/waveform-remap.mov")
    let first = VideoClip(
      sourceURL: source,
      sourceStart: 0,
      duration: 2,
      sourceDuration: 4
    )
    let second = VideoClip(
      sourceURL: source,
      sourceStart: 2,
      duration: 2,
      sourceDuration: 4
    )
    let waveform: [Float] = [0.1, 0.2, 0.7, 0.8]

    let reordered = WaveformPresentation.remapped(
      waveform,
      from: [first, second],
      to: [second, first]
    )
    XCTAssertEqual(reordered, [0.7, 0.8, 0.1, 0.2])

    var trimmed = second
    trimmed.sourceStart = 3
    trimmed.duration = 1
    let trimmedWaveform = WaveformPresentation.remapped(
      waveform,
      from: [first, second],
      to: [trimmed]
    )
    XCTAssertEqual(trimmedWaveform, [0.8])
  }

  func testAutomaticColorRespondsToExposureAndColorCast() {
    let darkAndBlue = AutoColorAnalyzer.suggestedSettings(
      luminance: [0.05, 0.08, 0.12, 0.18, 0.22],
      red: 10,
      blue: 16,
      averageChroma: 0.12
    )
    XCTAssertGreaterThan(darkAndBlue.brightness, 0)
    XCTAssertGreaterThan(darkAndBlue.warmth, 0)
    XCTAssertGreaterThan(darkAndBlue.saturation, 1)

    let brightAndWarm = AutoColorAnalyzer.suggestedSettings(
      luminance: [0.72, 0.78, 0.84, 0.90],
      red: 18,
      blue: 10,
      averageChroma: 0.28
    )
    XCTAssertLessThan(brightAndWarm.brightness, 0)
    XCTAssertLessThan(brightAndWarm.warmth, 0)
    XCTAssertLessThan(brightAndWarm.saturation, 1)
  }

  func testVerticalCaptionDefaultUsesSocialSafeArea() {
    let style = CaptionStyle.defaultStyle(for: .vertical)
    let safeArea = try! XCTUnwrap(CanvasPreset.vertical.socialSafeArea)

    XCTAssertEqual(style.normalizedY, 0.70)
    XCTAssertTrue(safeArea.contains(CGPoint(x: style.normalizedX, y: style.normalizedY)))
    XCTAssertNil(CanvasPreset.horizontal.socialSafeArea)
    XCTAssertEqual(
      CaptionStyle().adaptingBuiltInPosition(to: .vertical).normalizedY,
      0.70
    )
    XCTAssertEqual(
      CaptionStyle(normalizedY: 0.61).adaptingBuiltInPosition(to: .vertical)
        .normalizedY,
      0.61
    )
  }

  @MainActor
  func testLeadingTrimPreviewMovesGrabbedEdgeAndLeavesTemporaryGap() {
    let clip = VideoClip(
      sourceURL: URL(fileURLWithPath: "/tmp/trim-preview.mov"),
      sourceStart: 2,
      duration: 4,
      sourceDuration: 10
    )
    let preview = TrimPreviewGeometry.adjustment(
      for: clip,
      edge: .leading,
      translation: 80,
      pixelsPerSecond: 100
    )

    XCTAssertEqual(preview.offset, 80)
    XCTAssertEqual(preview.width, -80)
    XCTAssertEqual(preview.offset + preview.width, 0)
  }

  @MainActor
  func testCommittedTrimCreatesOneUndoStep() {
    let project = EditorProject(loadRecovery: false)
    let clip = VideoClip(
      sourceURL: URL(fileURLWithPath: "/tmp/interactive-trim.mov"),
      sourceStart: 0,
      duration: 4,
      sourceDuration: 4
    )
    project.clips = [clip]

    project.resizeClip(id: clip.id, edge: .trailing, by: -1)
    XCTAssertEqual(project.duration, 3)

    project.undo()
    XCTAssertEqual(project.duration, 4)
    XCTAssertFalse(project.canUndo)
  }

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
    XCTAssertEqual(CanvasPreset.vertical.aspectRatio, 9.0 / 16.0)
    XCTAssertEqual(CanvasPreset.horizontal.aspectRatio, 16.0 / 9.0)
    XCTAssertEqual(CanvasPreset.square.aspectRatio, 1)
    XCTAssertTrue(CanvasPreset.vertical.title.contains("Вертикальный"))
    XCTAssertTrue(CanvasPreset.horizontal.title.contains("Горизонтальный"))
    XCTAssertTrue(CanvasPreset.square.title.contains("Квадратный"))
  }

  func testProjectFileRecognitionRejectsUnrelatedPackages() {
    XCTAssertTrue(
      ProjectPackageService.canOpen(
        URL(fileURLWithPath: "/tmp/Монтаж.simplecut")
      )
    )
    XCTAssertTrue(
      ProjectPackageService.canOpen(
        URL(fileURLWithPath: "/tmp/Монтаж.json")
      )
    )
    XCTAssertFalse(
      ProjectPackageService.canOpen(
        URL(fileURLWithPath: "/Applications/Other.app")
      )
    )
  }

  @MainActor
  func testBlankProjectNameHasReadableDisplayName() {
    let project = EditorProject(loadRecovery: false)
    project.name = " \n "
    XCTAssertEqual(project.displayName, "Без названия")
    project.name = "  Мой ролик  "
    XCTAssertEqual(project.displayName, "Мой ролик")
  }

  @MainActor
  func testNewProjectUsesLocalizedVideoNameAndResetRefreshesIt() {
    let timeZone = TimeZone(secondsFromGMT: 3 * 60 * 60)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let firstDate = calendar.date(
      from: DateComponents(
        year: 2026,
        month: 8,
        day: 7,
        hour: 16,
        minute: 10
      )
    )!
    let secondDate = calendar.date(
      from: DateComponents(
        year: 2026,
        month: 8,
        day: 8,
        hour: 9,
        minute: 5
      )
    )!
    var currentDate = firstDate
    let project = EditorProject(
      loadRecovery: false,
      now: { currentDate },
      namingTimeZone: timeZone
    )

    XCTAssertEqual(
      EditorProject.defaultName(for: firstDate, timeZone: timeZone),
      "Видео 2026-08-07 16-10"
    )
    XCTAssertEqual(project.name, "Видео 2026-08-07 16-10")

    currentDate = secondDate
    project.reset()

    XCTAssertEqual(project.name, "Видео 2026-08-08 09-05")
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

  func testLegacyOverlayGetsCaptionStyleDefaults() throws {
    let json = """
      {
        "id": "\(UUID().uuidString)",
        "kind": "caption",
        "startTime": 0,
        "duration": 1,
        "text": "Старый проект",
        "fontSize": 58,
        "foregroundHex": "#FFFFFF",
        "backgroundHex": "#000000B3"
      }
      """
    let item = try JSONDecoder().decode(
      OverlayItem.self,
      from: Data(json.utf8)
    )

    XCTAssertEqual(item.fontName, "Helvetica Neue")
    XCTAssertEqual(item.fontWeight, .semibold)
    XCTAssertEqual(item.strokeHex, "#000000FF")
    XCTAssertEqual(item.strokeWidth, 0)
    XCTAssertEqual(item.textPadding, 12)
    XCTAssertEqual(item.cornerRadius, 8)
    XCTAssertTrue(item.backgroundEnabled)
  }

  func testLegacyTransparentBackgroundIsMigratedAsDisabled() throws {
    let json = """
      {
        "kind": "text",
        "startTime": 0,
        "duration": 1,
        "text": "Без подложки",
        "backgroundHex": "#00000000"
      }
      """

    let item = try JSONDecoder().decode(
      OverlayItem.self,
      from: Data(json.utf8)
    )

    XCTAssertFalse(item.backgroundEnabled)
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
  func testSplitUsesAnchoredPlayheadWhenSkimmerIsNotVisible() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 6
      )
    ]

    project.seek(to: 2)
    project.scrub(to: 4)
    project.playback.timelineSkimmerTime = nil
    project.splitAtPlayhead()

    XCTAssertEqual(project.clips.map(\.duration), [2, 4])
  }

  @MainActor
  func testSplitPrefersVisibleTimelineSkimmer() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 6
      )
    ]

    project.seek(to: 2)
    project.playback.timelineSkimmerTime = 4
    project.splitAtPlayhead()

    XCTAssertEqual(project.clips.map(\.duration), [4, 2])
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
  func testClipCanMoveToTimelineInsertionPointAndUndoAsOneEdit() {
    let project = EditorProject(loadRecovery: false)
    let clips = (0..<3).map { index in
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/reorder-\(index).mov"),
        sourceStart: 0,
        duration: Double(index + 1)
      )
    }
    project.clips = clips

    XCTAssertTrue(
      project.moveClip(id: clips[0].id, toInsertionIndex: clips.count)
    )
    XCTAssertEqual(
      project.clips.map(\.id),
      [clips[1].id, clips[2].id, clips[0].id]
    )
    XCTAssertEqual(project.selectedClipIDs, [clips[0].id])

    project.undo()

    XCTAssertEqual(project.clips.map(\.id), clips.map(\.id))
  }

  @MainActor
  func testDroppingClipAtItsCurrentBoundaryDoesNotCreateUndoStep() {
    let project = EditorProject(loadRecovery: false)
    let clips = (0..<2).map { index in
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/noop-reorder-\(index).mov"),
        sourceStart: 0,
        duration: 1
      )
    }
    project.clips = clips

    XCTAssertFalse(project.moveClip(id: clips[0].id, toInsertionIndex: 1))
    XCTAssertEqual(project.clips.map(\.id), clips.map(\.id))
    XCTAssertFalse(project.canUndo)
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
  func testDeletingLastClipClearsPlaybackStateSynchronously() {
    let project = EditorProject(loadRecovery: false)
    let clip = VideoClip(
      sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
      sourceStart: 0,
      duration: 1,
      sourceDuration: 1
    )
    project.clips = [clip]
    project.waveform = [0.5]
    project.timelineZoom = 4
    project.player.replaceCurrentItem(
      with: AVPlayerItem(asset: AVMutableComposition())
    )
    project.selectClip(id: clip.id)

    project.deleteSelectedClips()

    XCTAssertTrue(project.clips.isEmpty)
    XCTAssertNil(project.player.currentItem)
    XCTAssertTrue(project.waveform.isEmpty)
    XCTAssertEqual(project.playhead, 0)
    XCTAssertEqual(project.timelineZoom, 1)
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

  func testPreviewAtTimelineEndUsesLastVisibleFrame() {
    XCTAssertEqual(
      EditorProject.previewTime(for: 33.3, duration: 33.3),
      33.3 - 1.0 / 30.0,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      EditorProject.previewTime(for: 12.4, duration: 33.3),
      12.4,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      EditorProject.previewTime(for: 0, duration: 0),
      0
    )
  }

  @MainActor
  func testSeekingBetweenEditPointsUsesClipBoundaries() {
    let source = URL(fileURLWithPath: "/tmp/source.mov")
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(sourceURL: source, sourceStart: 0, duration: 2),
      VideoClip(sourceURL: source, sourceStart: 2, duration: 3),
      VideoClip(sourceURL: source, sourceStart: 5, duration: 4),
    ]

    project.seek(to: 4)
    project.seekToPreviousEdit()
    XCTAssertEqual(project.playhead, 2)
    project.seekToPreviousEdit()
    XCTAssertEqual(project.playhead, 0)

    project.seekToNextEdit()
    XCTAssertEqual(project.playhead, 2)
    project.seekToNextEdit()
    XCTAssertEqual(project.playhead, 5)
    project.seekToNextEdit()
    XCTAssertEqual(project.playhead, 9)
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
  func testCaptionRegenerationKeepsCurrentProjectStyle() {
    let defaults = isolatedCaptionStyleDefaults()
    let project = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: defaults
    )
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    _ = project.replaceCaptions(with: [
      CaptionDraft(text: "Первая версия", startTime: 0, endTime: 1)
    ])
    project.overlays[0].fontSize = 91
    project.overlays[0].strokeHex = "#FF00FFFF"
    project.overlays[0].strokeWidth = 7
    project.overlays[0].normalizedY = 0.63

    let regenerated = project.replaceCaptions(with: [
      CaptionDraft(text: "Новая версия", startTime: 1, endTime: 2),
      CaptionDraft(text: "Ещё одна", startTime: 2, endTime: 3),
    ])

    XCTAssertEqual(regenerated.count, 2)
    XCTAssertTrue(regenerated.allSatisfy {
      $0.fontSize == 91
        && $0.strokeHex == "#FF00FFFF"
        && $0.strokeWidth == 7
        && $0.normalizedY == 0.63
    })
  }

  @MainActor
  func testSavedCaptionStyleIsUsedByANewProject() {
    let defaults = isolatedCaptionStyleDefaults()
    let firstProject = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: defaults
    )
    firstProject.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    _ = firstProject.replaceCaptions(with: [
      CaptionDraft(text: "Сохранить", startTime: 0, endTime: 1)
    ])
    firstProject.overlays[0].fontName = "Georgia"
    firstProject.overlays[0].fontSize = 76
    firstProject.overlays[0].foregroundHex = "#11AA33FF"
    firstProject.overlays[0].normalizedX = 0.42
    firstProject.saveCurrentCaptionStyle()

    let secondProject = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: defaults
    )
    secondProject.clips = firstProject.clips
    let captions = secondProject.replaceCaptions(with: [
      CaptionDraft(text: "Применить", startTime: 0, endTime: 1)
    ])

    XCTAssertTrue(secondProject.hasSavedCaptionStyle)
    XCTAssertEqual(captions[0].fontName, "Georgia")
    XCTAssertEqual(captions[0].fontSize, 76)
    XCTAssertEqual(captions[0].foregroundHex, "#11AA33FF")
    XCTAssertEqual(captions[0].normalizedX, 0.42)
  }

  @MainActor
  func testTextOverlayCanSaveAndReuseCustomStyle() {
    let defaults = isolatedCaptionStyleDefaults()
    let project = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: defaults
    )
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    project.addText()
    let overlayID = try! XCTUnwrap(project.overlays.first?.id)
    project.overlays[0].fontName = "Georgia"
    project.overlays[0].fontSize = 88
    project.overlays[0].strokeHex = "#FF00FFFF"
    project.overlays[0].strokeWidth = 6
    project.overlays[0].backgroundEnabled = false
    project.overlays[0].textPadding = 21
    project.overlays[0].cornerRadius = 14
    project.overlays[0].normalizedWidth = 0.73
    project.overlays[0].textAlignment = .right

    project.saveStyle(from: overlayID)
    project.overlays[0].fontName = "Arial"
    project.overlays[0].fontSize = 30
    project.overlays[0].textAlignment = .left
    project.applySavedStyle(to: overlayID)

    XCTAssertTrue(project.savedCaptionStyles.isEmpty)
    XCTAssertEqual(project.savedTextStyles.map(\.name), ["Мой стиль"])
    XCTAssertEqual(project.overlays[0].fontName, "Georgia")
    XCTAssertEqual(project.overlays[0].fontSize, 88)
    XCTAssertEqual(project.overlays[0].strokeHex, "#FF00FFFF")
    XCTAssertEqual(project.overlays[0].strokeWidth, 6)
    XCTAssertFalse(project.overlays[0].backgroundEnabled)
    XCTAssertEqual(project.overlays[0].textPadding, 21)
    XCTAssertEqual(project.overlays[0].cornerRadius, 14)
    XCTAssertEqual(project.overlays[0].normalizedWidth, 0.73)
    XCTAssertEqual(project.overlays[0].textAlignment, .right)
    XCTAssertTrue(project.canDeleteSavedStyle(for: overlayID))
  }

  @MainActor
  func testMultilineTextRendersTallerAndKeepsExplicitLineBreaks() {
    let singleLine = OverlayItem(
      kind: .text,
      startTime: 0,
      duration: 1,
      normalizedWidth: 0.7,
      text: "Первая строка",
      fontSize: 54,
      textAlignment: .left
    )
    var multiline = singleLine
    multiline.text = "Первая строка\nВторая строка\nТретья строка"
    multiline.textAlignment = .right

    let singleRender = CaptionRenderer.render(
      item: singleLine,
      canvasSize: CGSize(width: 1_080, height: 1_920)
    )
    let multilineRender = CaptionRenderer.render(
      item: multiline,
      canvasSize: CGSize(width: 1_080, height: 1_920)
    )

    XCTAssertGreaterThan(
      try! XCTUnwrap(multilineRender).size.height,
      try! XCTUnwrap(singleRender).size.height
    )
    XCTAssertEqual(multiline.text, "Первая строка\nВторая строка\nТретья строка")
    XCTAssertEqual(multiline.textAlignment, .right)
  }

  @MainActor
  func testDisabledBackgroundRemovesItsPaddingFromRender() {
    let withBackground = OverlayItem(
      kind: .text,
      startTime: 0,
      duration: 1,
      text: "Текст",
      backgroundEnabled: true,
      textPadding: 30
    )
    var withoutBackground = withBackground
    withoutBackground.backgroundEnabled = false

    let renderedWithBackground = CaptionRenderer.render(
      item: withBackground,
      canvasSize: CGSize(width: 1_080, height: 1_920)
    )
    let renderedWithoutBackground = CaptionRenderer.render(
      item: withoutBackground,
      canvasSize: CGSize(width: 1_080, height: 1_920)
    )

    XCTAssertGreaterThan(
      try! XCTUnwrap(renderedWithBackground).size.height,
      try! XCTUnwrap(renderedWithoutBackground).size.height
    )
  }

  func testLegacyCaptionStyleDefaultsToCenteredAlignment() throws {
    let data = Data(
      """
      {
        "fontSize": 72,
        "fontName": "Georgia",
        "fontWeight": "bold"
      }
      """.utf8
    )

    let style = try JSONDecoder().decode(CaptionStyle.self, from: data)

    XCTAssertEqual(style.textAlignment, .center)
    XCTAssertEqual(style.fontSize, 72)
    XCTAssertEqual(style.fontName, "Georgia")
  }

  @MainActor
  func testNamedTextAndCaptionStylesAreIndependent() {
    let defaults = isolatedCaptionStyleDefaults()
    let project = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: defaults
    )
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    let captions = project.replaceCaptions(with: [
      CaptionDraft(text: "Caption", startTime: 0, endTime: 1)
    ])
    project.addText()
    let captionID = try! XCTUnwrap(captions.first?.id)
    let textID = try! XCTUnwrap(
      project.overlays.first(where: { $0.kind == .text })?.id
    )
    let captionIndex = try! XCTUnwrap(
      project.overlays.firstIndex(where: { $0.id == captionID })
    )
    let textIndex = try! XCTUnwrap(
      project.overlays.firstIndex(where: { $0.id == textID })
    )

    project.overlays[captionIndex].fontSize = 70
    project.saveStyle(named: "Крупные субтитры", from: captionID)
    project.overlays[captionIndex].fontSize = 48
    project.saveStyle(named: "Мелкие субтитры", from: captionID)
    project.overlays[textIndex].fontSize = 92
    project.saveStyle(named: "Заголовок", from: textID)

    XCTAssertEqual(
      project.savedCaptionStyles.map(\.name),
      ["Крупные субтитры", "Мелкие субтитры"]
    )
    XCTAssertEqual(project.savedTextStyles.map(\.name), ["Заголовок"])

    project.overlays[captionIndex].fontSize = 20
    project.overlays[textIndex].fontSize = 20
    project.applySavedStyle(named: "Крупные субтитры", to: captionID)

    XCTAssertEqual(project.overlays[captionIndex].fontSize, 70)
    XCTAssertEqual(project.overlays[textIndex].fontSize, 20)

    project.applySavedStyle(named: "Заголовок", to: textID)

    XCTAssertEqual(project.overlays[captionIndex].fontSize, 70)
    XCTAssertEqual(project.overlays[textIndex].fontSize, 92)

    project.deleteStyle(
      named: "Мелкие субтитры",
      for: .caption
    )

    XCTAssertEqual(
      project.savedCaptionStyles.map(\.name),
      ["Крупные субтитры"]
    )
    XCTAssertEqual(project.savedTextStyles.map(\.name), ["Заголовок"])
  }

  @MainActor
  func testDeletingSavedCaptionStyleRestoresClassicForFutureProjects() {
    let defaults = isolatedCaptionStyleDefaults()
    CaptionStyleStore.saveCustom(
      CaptionStyle(fontSize: 103, fontName: "Menlo"),
      in: defaults
    )
    let project = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: defaults
    )

    project.deleteSavedCaptionStyle()

    XCTAssertFalse(project.hasSavedCaptionStyle)
    XCTAssertNil(CaptionStyleStore.customStyle(in: defaults))
    XCTAssertEqual(
      CaptionStyleStore.activeStyle(in: defaults),
      CaptionStylePreset.classic.style
    )
  }

  @MainActor
  func testLargeV3IsTheDefaultTranscriptionModel() {
    let project = EditorProject(
      loadRecovery: false,
      captionStyleDefaults: isolatedCaptionStyleDefaults()
    )

    XCTAssertEqual(project.transcriptionModel, .accurate)
  }

  @MainActor
  func testCaptionsCanBeSplitIntoTimedWordsWithoutChangingTotalRange() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    _ = project.replaceCaptions(with: [
      CaptionDraft(text: "одно длинное слово", startTime: 1, endTime: 4)
    ])

    project.splitCaptionsIntoWords()

    let captions = project.overlays.filter { $0.kind == .caption }
    XCTAssertEqual(captions.map(\.text), ["одно", "длинное", "слово"])
    XCTAssertEqual(captions.first?.startTime, 1)
    XCTAssertEqual(
      captions.reduce(0) { $0 + $1.duration },
      3,
      accuracy: 0.0001
    )
    let last = try! XCTUnwrap(captions.last)
    XCTAssertEqual(
      last.startTime + last.duration,
      4,
      accuracy: 0.0001
    )
  }

  @MainActor
  func testMovingCaptionPositionMovesTheWholeCaptionGroup() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    _ = project.replaceCaptions(with: [
      CaptionDraft(text: "Первая", startTime: 0, endTime: 1),
      CaptionDraft(text: "Вторая", startTime: 1, endTime: 2),
    ])

    project.setCaptionPosition(normalizedX: 0.25, normalizedY: 0.7)

    XCTAssertTrue(
      project.overlays
        .filter { $0.kind == .caption }
        .allSatisfy {
          $0.normalizedX == 0.25 && $0.normalizedY == 0.7
        }
    )
  }

  @MainActor
  func testSelectedCaptionCanBeDeletedWithoutDeletingClips() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    let captions = project.replaceCaptions(with: [
      CaptionDraft(text: "Удалить", startTime: 0, endTime: 1),
      CaptionDraft(text: "Оставить", startTime: 1, endTime: 2),
    ])
    project.selectOverlay(id: captions[0].id)

    project.deleteSelectedOverlay()

    XCTAssertEqual(project.clips.count, 1)
    XCTAssertEqual(
      project.overlays.filter { $0.kind == .caption }.map(\.text),
      ["Оставить"]
    )
    XCTAssertNil(project.selectedOverlayID)
  }

  @MainActor
  func testAllCaptionsCanBeDeletedAndRestoredWithUndo() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
        sourceStart: 0,
        duration: 5
      )
    ]
    _ = project.replaceCaptions(with: [
      CaptionDraft(text: "Первый", startTime: 0, endTime: 1),
      CaptionDraft(text: "Второй", startTime: 1, endTime: 2),
    ])

    project.deleteAllCaptions()

    XCTAssertTrue(project.overlays.allSatisfy { $0.kind != .caption })
    XCTAssertNil(project.selectedOverlayID)
    XCTAssertEqual(project.status, "Субтитры удалены")

    project.undo()

    XCTAssertEqual(
      project.overlays.filter { $0.kind == .caption }.count,
      2
    )
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
  func testRepeatedOverlaySelectionRequestsInspectorFocus() {
    let project = EditorProject(loadRecovery: false)
    let overlay = OverlayItem(
      kind: .text,
      startTime: 0,
      duration: 1,
      text: "Text"
    )
    project.overlays = [overlay]
    let initialRequest = project.inspectorFocusRequestID

    project.selectOverlay(id: overlay.id)
    let firstRequest = project.inspectorFocusRequestID
    project.selectOverlay(id: overlay.id)
    let secondRequest = project.inspectorFocusRequestID

    XCTAssertNotEqual(firstRequest, initialRequest)
    XCTAssertNotEqual(secondRequest, firstRequest)
    XCTAssertEqual(project.selectedOverlayID, overlay.id)
  }

  @MainActor
  func testOverlayKindsHaveConsistentTimelineAndCompositingOrder() {
    let image = OverlayItem(
      kind: .image,
      startTime: 0,
      duration: 1
    )
    let text = OverlayItem(
      kind: .text,
      startTime: 0,
      duration: 1,
      text: "Text"
    )
    let caption = OverlayItem(
      kind: .caption,
      startTime: 0,
      duration: 1,
      text: "Caption"
    )
    let overlays = [caption, text, image]

    XCTAssertEqual(
      OverlayKind.timelineKinds(for: overlays),
      [.text, .caption, .image]
    )
    XCTAssertEqual(
      overlays.inCompositingOrder.map(\.kind),
      [.image, .caption, .text]
    )
  }

  @MainActor
  func testOverlayWidthResizeClampsAndKeepsCaptionWidthsTogether() {
    let project = EditorProject(loadRecovery: false)
    let firstCaption = OverlayItem(
      kind: .caption,
      startTime: 0,
      duration: 1,
      text: "First"
    )
    let secondCaption = OverlayItem(
      kind: .caption,
      startTime: 1,
      duration: 1,
      text: "Second"
    )
    let image = OverlayItem(
      kind: .image,
      startTime: 0,
      duration: 2
    )
    project.overlays = [firstCaption, secondCaption, image]

    project.setOverlayWidth(
      id: firstCaption.id,
      normalizedWidth: 0.72
    )
    project.setOverlayWidth(id: image.id, normalizedWidth: 2)

    XCTAssertEqual(project.overlays[0].normalizedWidth, 0.72)
    XCTAssertEqual(project.overlays[1].normalizedWidth, 0.72)
    XCTAssertEqual(project.overlays[2].normalizedWidth, 1)
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

  private func isolatedCaptionStyleDefaults() -> UserDefaults {
    let suiteName = "SimpleCutTests.CaptionStyle.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
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
