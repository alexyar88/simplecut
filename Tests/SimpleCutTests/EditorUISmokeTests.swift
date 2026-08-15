import AppKit
import SwiftUI
import XCTest

@testable import SimpleCut

final class EditorUISmokeTests: XCTestCase {
  @MainActor
  func testEditorViewConstructsAndLaysOut() {
    let project = EditorProject(loadRecovery: false)
    let view = EditorView()
      .environmentObject(project)
      .frame(width: 1_080, height: 700)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 700)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
  }

  @MainActor
  func testEditorViewWithPopulatedTimelineConstructsAndLaysOut() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/timeline-smoke.mov")
    project.clips = [
      VideoClip(sourceURL: source, sourceStart: 0, duration: 2),
      VideoClip(sourceURL: source, sourceStart: 2, duration: 3),
      VideoClip(sourceURL: source, sourceStart: 5, duration: 4),
    ]
    project.overlays = [
      OverlayItem(
        kind: .text,
        startTime: 1,
        duration: 3,
        text: "Заголовок"
      )
    ]
    project.selectClip(id: project.clips[1].id)

    let view = EditorView()
      .environmentObject(project)
      .frame(width: 1_080, height: 700)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 1_080, height: 700)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
    XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
  }
}
