import AppKit
import SwiftUI

@main
struct SimpleCutApp: App {
  @StateObject private var project = EditorProject()

  var body: some Scene {
    Window("SimpleCut", id: "editor") {
      EditorView()
        .environmentObject(project)
        .frame(
          minWidth: 1080,
          maxWidth: .infinity,
          minHeight: 700,
          maxHeight: .infinity
        )
        .preferredColorScheme(.dark)
        .tint(EditorTheme.accent)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      SimpleCutCommands(project: project)
    }

    Window("Запись", id: "recording") {
      RecordView()
        .environmentObject(project)
        .preferredColorScheme(.dark)
        .tint(EditorTheme.accent)
    }
    .defaultSize(width: 980, height: 680)
    .windowResizability(.contentSize)
  }
}

private struct SimpleCutCommands: Commands {
  @ObservedObject var project: EditorProject
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .undoRedo) {
      Button("Отменить") {
        project.undo()
      }
      .keyboardShortcut("z")
      .disabled(!project.canUndo)
      Button("Повторить") {
        project.redo()
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
      .disabled(!project.canRedo)
    }
    CommandGroup(replacing: .newItem) {
      Button("Новый проект") {
        postToEditor(.simpleCutNew)
      }
      .keyboardShortcut("n")
      Button("Открыть проект…") {
        postToEditor(.simpleCutOpen)
      }
      .keyboardShortcut("o")
    }
    CommandGroup(replacing: .saveItem) {
      Button("Сохранить") {
        postToEditor(.simpleCutSave)
      }
      .keyboardShortcut("s")
      Button("Сохранить как…") {
        postToEditor(.simpleCutSaveAs)
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }
    CommandGroup(replacing: .importExport) {
      Button("Импортировать видео…") {
        postToEditor(.simpleCutImport)
      }
      .keyboardShortcut("i")
      Button("Экспортировать…") {
        postToEditor(.simpleCutExport)
      }
      .keyboardShortcut("e")
    }
    CommandMenu("Монтаж") {
      Button("Выбрать все фрагменты") {
        project.selectAllClips()
      }
      .keyboardShortcut("a")
      Divider()
      Button("Разрезать") {
        project.splitAtPlayhead()
      }
      .keyboardShortcut("b")
      .disabled(!project.canSplitAtPlayhead)
      Button("Удалить фрагмент") {
        project.deleteSelectedClips()
      }
      .keyboardShortcut(.delete)
      .disabled(project.selectedClipIDs.isEmpty)
    }
  }

  private func postToEditor(_ name: Notification.Name) {
    let hasVisibleEditor = NSApp.windows.contains {
      $0.isVisible && $0.title == "SimpleCut"
    }
    if !hasVisibleEditor {
      openWindow(id: "editor")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      NotificationCenter.default.post(name: name, object: nil)
    }
  }
}

extension Notification.Name {
  static let simpleCutNew = Notification.Name("SimpleCut.new")
  static let simpleCutOpen = Notification.Name("SimpleCut.open")
  static let simpleCutSave = Notification.Name("SimpleCut.save")
  static let simpleCutSaveAs = Notification.Name("SimpleCut.saveAs")
  static let simpleCutImport = Notification.Name("SimpleCut.import")
  static let simpleCutExport = Notification.Name("SimpleCut.export")
}
