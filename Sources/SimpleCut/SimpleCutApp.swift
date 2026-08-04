import SwiftUI

@main
struct SimpleCutApp: App {
  @StateObject private var project = EditorProject()

  var body: some Scene {
    WindowGroup {
      EditorView()
        .environmentObject(project)
        .frame(minWidth: 1080, minHeight: 700)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
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
          project.reset()
        }
        .keyboardShortcut("n")
      }
      CommandGroup(replacing: .saveItem) {
        Button("Сохранить") {
          NotificationCenter.default.post(name: .simpleCutSave, object: nil)
        }
        .keyboardShortcut("s")
      }
      CommandGroup(replacing: .importExport) {
        Button("Импортировать видео…") {
          NotificationCenter.default.post(name: .simpleCutImport, object: nil)
        }
        .keyboardShortcut("i")
        Button("Экспортировать…") {
          NotificationCenter.default.post(name: .simpleCutExport, object: nil)
        }
        .keyboardShortcut("e")
      }
      CommandMenu("Монтаж") {
        Button("Разрезать") {
          project.splitAtPlayhead()
        }
        .keyboardShortcut("b")
        Button("Удалить фрагмент") {
          project.deleteSelectedClip()
        }
        .keyboardShortcut(.delete)
      }
    }
  }
}

extension Notification.Name {
  static let simpleCutSave = Notification.Name("SimpleCut.save")
  static let simpleCutImport = Notification.Name("SimpleCut.import")
  static let simpleCutExport = Notification.Name("SimpleCut.export")
}
