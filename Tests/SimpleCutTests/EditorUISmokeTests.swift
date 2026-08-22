import AppKit
import SwiftUI
import XCTest

@testable import SimpleCut

final class EditorUISmokeTests: XCTestCase {
  @MainActor
  func testBothTrimEdgesShowResizeCursorOnHoverBeforeMouseDown() {
    let event = NSEvent.enterExitEvent(
      with: .mouseEntered,
      location: NSPoint(x: 9, y: 50),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      trackingNumber: 1,
      userData: nil
    )!
    defer { NSCursor.arrow.set() }

    for edge in [TrimEdge.leading, .trailing] {
      let view = TimelineTrimHandleNSView(
        frame: NSRect(x: 0, y: 0, width: 18, height: 100)
      )
      view.edge = edge
      var hoverStates: [Bool] = []
      view.onHoverChanged = { hoverStates.append($0) }
      NSCursor.arrow.set()

      view.mouseEntered(with: event)

      XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
      XCTAssertEqual(hoverStates, [true], "Не сработал край: \(edge)")
    }
  }

  @MainActor
  func testExitingOneTrimEdgeDoesNotOverrideOtherEdgeCursor() {
    let leading = TimelineTrimHandleNSView()
    leading.edge = .leading
    let trailing = TimelineTrimHandleNSView()
    trailing.edge = .trailing
    defer { NSCursor.arrow.set() }

    leading.setHovering(true)
    trailing.setHovering(true)
    leading.setHovering(false)

    XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
  }

  @MainActor
  func testTrailingTrimCursorSurvivesRepeatedPointerReentryAndLayout() {
    let view = TimelineTrimHandleNSView(
      frame: NSRect(x: 0, y: 0, width: 21, height: 100)
    )
    view.edge = .trailing
    var hoverStates: [Bool] = []
    view.onHoverChanged = { hoverStates.append($0) }
    defer { NSCursor.arrow.set() }

    for _ in 0..<5 {
      NSCursor.arrow.set()
      view.setHovering(true)
      view.setFrameSize(NSSize(width: 21, height: 100))
      XCTAssertEqual(NSCursor.current, .resizeLeftRight)
      view.setHovering(false)
    }

    XCTAssertEqual(
      hoverStates,
      Array(repeating: [true, false], count: 5).flatMap { $0 }
    )
  }

  @MainActor
  func testRepeatedMovementInsideTrailingHandleDoesNotEmitHoverTransitions() {
    let view = TimelineTrimHandleNSView(
      frame: NSRect(x: 0, y: 0, width: 21, height: 100)
    )
    view.edge = .trailing
    var hoverStates: [Bool] = []
    view.onHoverChanged = { hoverStates.append($0) }
    let event = NSEvent.mouseEvent(
      with: .mouseMoved,
      location: NSPoint(x: 10, y: 50),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 0,
      pressure: 0
    )!
    defer { NSCursor.arrow.set() }

    for _ in 0..<20 {
      view.mouseMoved(with: event)
    }

    XCTAssertEqual(hoverStates, [true])
    XCTAssertEqual(NSCursor.current, .resizeLeftRight)
  }

  @MainActor
  func testTrimCursorsRemainAvailableAfterZoomSplitAndReorderRebuilds() {
    let project = EditorProject(loadRecovery: false)
    let source = URL(fileURLWithPath: "/tmp/timeline-cursor-rebuild.mov")
    project.clips = [
      VideoClip(
        sourceURL: source,
        sourceStart: 0,
        duration: 4,
        sourceDuration: 12
      ),
      VideoClip(
        sourceURL: source,
        sourceStart: 4,
        duration: 4,
        sourceDuration: 12
      ),
      VideoClip(
        sourceURL: source,
        sourceStart: 8,
        duration: 4,
        sourceDuration: 12
      ),
    ]

    let timeline = TimelineView(playback: project.playback)
      .environmentObject(project)
      .frame(width: 900, height: 260)
    let hostingView = NSHostingView(rootView: timeline)
    hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 260)
    let window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer {
      NSCursor.arrow.set()
      window.close()
    }

    assertTrimCursorAvailability(
      in: hostingView,
      expectedClipCount: 3,
      stage: "initial"
    )

    project.timelineZoom = 4
    refreshSwiftUILayout(hostingView)
    assertTrimCursorAvailability(
      in: hostingView,
      expectedClipCount: 3,
      stage: "zoom"
    )

    project.seek(to: 2)
    project.splitAtPlayhead()
    refreshSwiftUILayout(hostingView)
    assertTrimCursorAvailability(
      in: hostingView,
      expectedClipCount: 4,
      stage: "split"
    )

    let movedClipID = project.clips[3].id
    XCTAssertTrue(project.moveClip(id: movedClipID, toInsertionIndex: 0))
    refreshSwiftUILayout(hostingView)
    assertTrimCursorAvailability(
      in: hostingView,
      expectedClipCount: 4,
      stage: "reorder"
    )
  }

  @MainActor
  func testTimelineZoomAndSkimmerStayAnchoredThroughRealUIRebuilds() {
    let project = EditorProject(loadRecovery: false)
    project.clips = [
      VideoClip(
        sourceURL: URL(fileURLWithPath: "/tmp/timeline-zoom-anchor.mov"),
        sourceStart: 0,
        duration: 10
      )
    ]
    project.seek(to: 4)

    let timeline = TimelineView(playback: project.playback)
      .environmentObject(project)
      .frame(width: 900, height: 260)
    let hostingView = NSHostingView(rootView: timeline)
    hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 260)
    let window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer { window.close() }

    project.timelineZoom = 2
    refreshSwiftUILayout(hostingView)
    let controllers = descendantViews(
      of: TimelineZoomScrollControllerNSView.self,
      in: hostingView
    )
    let controller = try! XCTUnwrap(controllers.first)
    let scrollView = try! XCTUnwrap(controller.enclosingScrollView)
    let contentWidth = scrollView.documentView?.bounds.width ?? 0
    let viewportWidth = scrollView.contentSize.width
    let anchor = TimelineZoomAnchorGeometry(
      contentProgress: 0.4,
      viewportProgress: 0.25
    )
    let coordinator = TimelineScrollCoordinator()

    controller.schedule(
      coordinator: coordinator,
      request: nil,
      contentWidth: contentWidth,
      viewportWidth: viewportWidth
    )
    refreshSwiftUILayout(hostingView)
    let visiblePlayheadAnchor = coordinator.zoomAnchor(
      pointerViewportX: nil,
      playheadProgress: 0.4
    )
    XCTAssertEqual(visiblePlayheadAnchor.contentProgress, 0.4, accuracy: 0.001)
    XCTAssertEqual(
      visiblePlayheadAnchor.viewportProgress,
      (contentWidth * 0.4 - scrollView.contentView.bounds.origin.x)
        / viewportWidth,
      accuracy: 0.001
    )

    controller.schedule(
      coordinator: coordinator,
      request: TimelineZoomScrollRequest(id: UUID(), anchor: anchor),
      contentWidth: contentWidth,
      viewportWidth: viewportWidth
    )
    XCTAssertEqual(
      scrollView.contentView.bounds.origin.x,
      TimelineInteractionGeometry.zoomScrollOffset(
        anchor: anchor,
        contentWidth: contentWidth,
        viewportWidth: viewportWidth
      ),
      accuracy: 0.5,
      "Zoom anchor correction was deferred to a second frame"
    )
    refreshSwiftUILayout(hostingView)

    XCTAssertEqual(
      scrollView.contentView.bounds.origin.x,
      TimelineInteractionGeometry.zoomScrollOffset(
        anchor: anchor,
        contentWidth: contentWidth,
        viewportWidth: viewportWidth
      ),
      accuracy: 0.5
    )

    for zoom in [4.0, 1.5, 6.0, 2.25] {
      project.timelineZoom = zoom
      refreshSwiftUILayout(hostingView)
      let rebuiltController = try! XCTUnwrap(
        descendantViews(
          of: TimelineZoomScrollControllerNSView.self,
          in: hostingView
        ).first
      )
      let rebuiltScrollView = try! XCTUnwrap(
        rebuiltController.enclosingScrollView
      )
      let rebuiltContentWidth =
        rebuiltScrollView.documentView?.bounds.width ?? 0
      let rebuiltViewportWidth = rebuiltScrollView.contentSize.width
      rebuiltController.schedule(
        coordinator: coordinator,
        request: TimelineZoomScrollRequest(id: UUID(), anchor: anchor),
        contentWidth: rebuiltContentWidth,
        viewportWidth: rebuiltViewportWidth
      )
      refreshSwiftUILayout(hostingView)

      let pointerX = anchor.viewportProgress * rebuiltViewportWidth
      let progressUnderPointer =
        (rebuiltScrollView.contentView.bounds.origin.x + pointerX)
        / rebuiltContentWidth
      XCTAssertEqual(
        progressUnderPointer,
        anchor.contentProgress,
        accuracy: 0.001,
        "Timeline time under the pointer moved at zoom \(zoom)"
      )
    }

    func assertSkimmerMatchesPointer(_ stage: String) {
      let tracker = try! XCTUnwrap(
        descendantViews(
          of: TimelinePointerTrackingNSView.self,
          in: hostingView
        ).first
      )
      let expectedX = tracker.bounds.width * 0.63
      func pointerEvent(at x: CGFloat) -> NSEvent {
        let windowPoint = tracker.convert(
          NSPoint(x: x, y: tracker.bounds.midY),
          to: nil
        )
        return NSEvent.mouseEvent(
          with: .mouseMoved,
          location: windowPoint,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 1,
          clickCount: 0,
          pressure: 0
        )!
      }

      // The representable may survive a split on one SwiftUI version and be
      // recreated on another. Move away first so this probe never depends on
      // whether the view retained its duplicate-event suppression state.
      tracker.mouseMoved(with: pointerEvent(at: expectedX - 10))
      var reportedX: CGFloat?
      tracker.onMoved = { reportedX = $0 }
      tracker.mouseMoved(with: pointerEvent(at: expectedX))
      XCTAssertEqual(reportedX ?? -1, expectedX, accuracy: 0.5, stage)
      XCTAssertEqual(
        TimelineInteractionGeometry.viewportSkimmerX(
          pointerViewportX: reportedX ?? -1,
          viewportWidth: tracker.bounds.width
        ),
        expectedX,
        accuracy: 0.5,
        "White skimmer detached from the pointer after \(stage)"
      )
    }

    func assertSkimmerMagnetism(_ stage: String) {
      let controller = try! XCTUnwrap(
        descendantViews(
          of: TimelineZoomScrollControllerNSView.self,
          in: hostingView
        ).first
      )
      let scrollView = try! XCTUnwrap(controller.enclosingScrollView)
      let contentWidth = scrollView.documentView?.bounds.width ?? 0
      let viewportWidth = scrollView.contentSize.width
      let anchoredContentX = contentWidth
        * project.playback.anchoredPlayhead / project.duration
      let anchoredViewportX =
        anchoredContentX - scrollView.contentView.bounds.origin.x
      XCTAssertTrue(
        (8...(viewportWidth - 8)).contains(anchoredViewportX),
        "Test playhead must be visible after \(stage)"
      )

      let snapped = TimelineInteractionGeometry.viewportSkimmer(
        pointerViewportX: anchoredViewportX + 6,
        anchoredViewportX: anchoredViewportX,
        viewportWidth: viewportWidth,
        snapDistance: 7
      )
      XCTAssertTrue(snapped.isSnapped, "Magnetism was lost after \(stage)")
      XCTAssertEqual(snapped.x, anchoredViewportX, accuracy: 0.001)
      XCTAssertEqual(
        snapped.x + scrollView.contentView.bounds.origin.x,
        anchoredContentX,
        accuracy: 0.001,
        "Snapped skimmer points at a different time after \(stage)"
      )

      let free = TimelineInteractionGeometry.viewportSkimmer(
        pointerViewportX: anchoredViewportX + 8,
        anchoredViewportX: anchoredViewportX,
        viewportWidth: viewportWidth,
        snapDistance: 7
      )
      XCTAssertFalse(free.isSnapped)
      XCTAssertEqual(free.x, anchoredViewportX + 8, accuracy: 0.001)
    }

    assertSkimmerMatchesPointer("zoom sequence")
    assertSkimmerMagnetism("zoom sequence")
    project.seek(to: 5)
    project.splitAtPlayhead()
    refreshSwiftUILayout(hostingView)
    assertSkimmerMatchesPointer("split")
    assertSkimmerMagnetism("split")

    let scrolledController = try! XCTUnwrap(
      descendantViews(
        of: TimelineZoomScrollControllerNSView.self,
        in: hostingView
      ).first
    )
    let scrolledView = try! XCTUnwrap(scrolledController.enclosingScrollView)
    let origin = scrolledView.contentView.bounds.origin
    scrolledView.contentView.scroll(
      to: NSPoint(x: origin.x + 120, y: origin.y)
    )
    scrolledView.reflectScrolledClipView(scrolledView.contentView)
    refreshSwiftUILayout(hostingView)
    assertSkimmerMatchesPointer("horizontal scroll")
    assertSkimmerMagnetism("horizontal scroll")
  }

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
  private func assertTrimCursorAvailability(
    in root: NSView,
    expectedClipCount: Int,
    stage: String
  ) {
    refreshSwiftUILayout(root)
    let handles = descendantViews(
      of: TimelineTrimHandleNSView.self,
      in: root
    )
    XCTAssertEqual(
      handles.count,
      expectedClipCount * 2,
      "Trim handles were not rebuilt after \(stage)"
    )
    XCTAssertEqual(
      handles.filter { $0.edge == .leading }.count,
      expectedClipCount,
      "Leading trim handles are missing after \(stage)"
    )
    XCTAssertEqual(
      handles.filter { $0.edge == .trailing }.count,
      expectedClipCount,
      "Trailing trim handles are missing after \(stage)"
    )

    for handle in handles {
      NSCursor.arrow.set()
      handle.mouseEntered(with: trimEnterEvent(for: handle))
      XCTAssertEqual(
        NSCursor.current,
        .resizeLeftRight,
        "The \(handle.edge) cursor is unavailable after \(stage)"
      )
      handle.setHovering(false)
    }
  }

  @MainActor
  private func refreshSwiftUILayout(_ view: NSView) {
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    for _ in 0..<3 {
      _ = RunLoop.main.run(mode: .default, before: Date())
      view.layoutSubtreeIfNeeded()
    }
  }

  @MainActor
  private func descendantViews<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
  ) -> [ViewType] {
    root.subviews.flatMap { child in
      var matches = (child as? ViewType).map { [$0] } ?? []
      matches.append(contentsOf: descendantViews(of: type, in: child))
      return matches
    }
  }

  @MainActor
  private func trimEnterEvent(for view: NSView) -> NSEvent {
    NSEvent.enterExitEvent(
      with: .mouseEntered,
      location: NSPoint(x: view.bounds.midX, y: view.bounds.midY),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 1,
      trackingNumber: 1,
      userData: nil
    )!
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
