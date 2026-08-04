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
}
