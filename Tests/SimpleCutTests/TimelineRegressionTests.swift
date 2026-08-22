import CoreGraphics
import XCTest

@testable import SimpleCut

final class TimelineRegressionTests: XCTestCase {
  func testVisualClipGapDoesNotCreateATimelineGapOrLoseWaveformSamples() {
    let first = TimelineWaveformGeometry.segment(
      timelineStart: 0,
      clipDuration: 1.5,
      totalDuration: 4,
      trackWidth: 400,
      visualGap: 10,
      sampleCount: 400,
      trimEdge: nil,
      adjustment: TrimPreviewAdjustment(offset: 0, width: 0)
    )
    let second = TimelineWaveformGeometry.segment(
      timelineStart: 1.5,
      clipDuration: 2.5,
      totalDuration: 4,
      trackWidth: 400,
      visualGap: 10,
      sampleCount: 400,
      trimEdge: nil,
      adjustment: TrimPreviewAdjustment(offset: 0, width: 0)
    )

    XCTAssertEqual(first.logicalEndX, second.logicalStartX, accuracy: 0.0001)
    XCTAssertEqual(
      second.cardFrame.minX - first.cardFrame.maxX,
      10,
      accuracy: 0.0001
    )
    XCTAssertEqual(first.waveformFrame, first.cardFrame)
    XCTAssertEqual(second.waveformFrame, second.cardFrame)
    XCTAssertEqual(first.sampleRange, 0..<150)
    XCTAssertEqual(second.sampleRange, 150..<400)
    XCTAssertEqual(first.sampleRange.upperBound, second.sampleRange.lowerBound)
  }

  func testLeadingTrimGuideAndWaveformUseTheCommittedTimeCoordinate() {
    let geometry = TimelineWaveformGeometry.segment(
      timelineStart: 1.5,
      clipDuration: 2.5,
      totalDuration: 4,
      trackWidth: 400,
      visualGap: 10,
      sampleCount: 400,
      trimEdge: .leading,
      adjustment: TrimPreviewAdjustment(offset: 40, width: -40)
    )

    // Forty pixels at 100 px/s is a 0.4-second source trim.
    XCTAssertEqual(geometry.logicalStartX, 190, accuracy: 0.0001)
    XCTAssertEqual(geometry.cardFrame.minX, 195, accuracy: 0.0001)
    XCTAssertEqual(geometry.sampleRange, 190..<400)
    XCTAssertEqual(
      geometry.cardFrame.minX - geometry.logicalStartX,
      5,
      accuracy: 0.0001
    )
  }

  func testTrailingTrimRemovesSamplesFromTheEndWithoutMovingTheStart() {
    let geometry = TimelineWaveformGeometry.segment(
      timelineStart: 1,
      clipDuration: 2,
      totalDuration: 4,
      trackWidth: 400,
      visualGap: 10,
      sampleCount: 400,
      trimEdge: .trailing,
      adjustment: TrimPreviewAdjustment(offset: 0, width: -25)
    )

    XCTAssertEqual(geometry.logicalStartX, 100, accuracy: 0.0001)
    XCTAssertEqual(geometry.logicalEndX, 275, accuracy: 0.0001)
    XCTAssertEqual(geometry.sampleRange, 100..<275)
    XCTAssertEqual(geometry.cardFrame.minX, 105, accuracy: 0.0001)
    XCTAssertEqual(geometry.cardFrame.maxX, 270, accuracy: 0.0001)
  }

  func testRestoringAHandleDoesNotStretchUnknownWaveformSamples() {
    let geometry = TimelineWaveformGeometry.segment(
      timelineStart: 1,
      clipDuration: 2,
      totalDuration: 4,
      trackWidth: 400,
      visualGap: 10,
      sampleCount: 400,
      trimEdge: .leading,
      adjustment: TrimPreviewAdjustment(offset: -30, width: 30)
    )

    XCTAssertEqual(geometry.cardFrame.minX, 75, accuracy: 0.0001)
    XCTAssertEqual(geometry.waveformFrame.minX, 105, accuracy: 0.0001)
    XCTAssertEqual(geometry.waveformFrame.width, 190, accuracy: 0.0001)
    XCTAssertEqual(geometry.sampleRange, 100..<300)
  }

  func testSkimmerIsHiddenOnlyWhileTrimming() {
    XCTAssertEqual(
      TimelineInteractionGeometry.visibleSkimmerX(123, isTrimming: false),
      123
    )
    XCTAssertNil(
      TimelineInteractionGeometry.visibleSkimmerX(123, isTrimming: true)
    )
    XCTAssertNil(
      TimelineInteractionGeometry.visibleSkimmerX(nil, isTrimming: false)
    )
  }

  func testClipMetadataUsesAdaptiveWidthThresholds() {
    XCTAssertFalse(TimelineInteractionGeometry.showsClipIndex(width: 33.9))
    XCTAssertTrue(TimelineInteractionGeometry.showsClipIndex(width: 34))
    XCTAssertFalse(TimelineInteractionGeometry.showsClipDuration(width: 95.9))
    XCTAssertTrue(TimelineInteractionGeometry.showsClipDuration(width: 96))
  }
}
