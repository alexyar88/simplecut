import AppKit
import SwiftUI

struct PreviewCanvas: View {
  @EnvironmentObject private var project: EditorProject
  @State private var draggingOverlayID: UUID?

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black
        PlayerView(player: project.player)

        ForEach(project.overlays) { item in
          if project.playhead >= item.startTime,
            project.playhead <= item.startTime + item.duration
          {
            overlay(item, in: proxy.size)
          }
        }
      }
      .aspectRatio(
        project.canvas.size.width / project.canvas.size.height,
        contentMode: .fit
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
  }

  @ViewBuilder
  private func overlay(_ item: OverlayItem, in size: CGSize) -> some View {
    let width = max(90, size.width * item.normalizedWidth)
    Group {
      switch item.kind {
      case .text, .caption:
        Text(item.text ?? "")
          .font(
            .system(
              size: max(12, item.fontSize * size.width / 1080),
              weight: .semibold)
          )
          .foregroundStyle(Color(nsColor: NSColor(hex: item.foregroundHex)))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            Color(nsColor: NSColor(hex: item.backgroundHex)),
            in: RoundedRectangle(cornerRadius: 8)
          )
      case .image:
        if let url = item.imageURL,
          let image = NSImage(contentsOf: url)
        {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
        }
      }
    }
    .frame(width: width)
    .opacity(item.opacity)
    .rotationEffect(.degrees(item.rotation))
    .overlay {
      if project.selectedOverlayID == item.id {
        RoundedRectangle(cornerRadius: 5)
          .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [5]))
      }
    }
    .position(
      x: size.width * item.normalizedX,
      y: size.height * item.normalizedY
    )
    .contentShape(Rectangle())
    .onTapGesture {
      project.selectedOverlayID = item.id
    }
    .gesture(
      DragGesture()
        .onChanged { value in
          guard
            let index = project.overlays.firstIndex(
              where: { $0.id == item.id }
            )
          else { return }
          if draggingOverlayID != item.id {
            project.recordUndoCheckpoint()
            draggingOverlayID = item.id
          }
          project.selectedOverlayID = item.id
          project.overlays[index].normalizedX = min(
            1,
            max(0, value.location.x / max(size.width, 1))
          )
          project.overlays[index].normalizedY = min(
            1,
            max(0, value.location.y / max(size.height, 1))
          )
        }
        .onEnded { _ in
          draggingOverlayID = nil
        }
    )
  }
}
