import AppKit
import SwiftUI

struct PreviewCanvas: View {
  @EnvironmentObject private var project: EditorProject
  @State private var draggingOverlayID: UUID?

  var body: some View {
    GeometryReader { proxy in
      let canvasSize = fittedCanvasSize(in: proxy.size)
      ZStack {
        Color.black
        PlayerView(player: project.player, scalingMode: project.scalingMode)
          .brightness(project.color.brightness)
          .contrast(project.color.contrast)
          .saturation(project.color.saturation)
          .colorMultiply(
            Color(
              red: 1,
              green: 1 - max(0, project.color.warmth) * 0.06,
              blue: 1 - max(0, project.color.warmth) * 0.12
            )
          )

        ForEach(project.overlays) { item in
          if project.playhead >= item.startTime,
            project.playhead <= item.startTime + item.duration
          {
            overlay(item, in: canvasSize)
          }
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .coordinateSpace(name: "previewCanvas")
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      .clipped()
    }
  }

  @ViewBuilder
  private func overlay(_ item: OverlayItem, in size: CGSize) -> some View {
    let width = max(90, size.width * item.normalizedWidth)
    let canvasScale = size.width / max(project.canvas.size.width, 1)
    Group {
      switch item.kind {
      case .text, .caption:
        if let rendered = CaptionRenderer.render(
          item: item,
          canvasSize: project.canvas.size
        ) {
          Image(decorative: rendered.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(
              width: rendered.size.width * canvasScale,
              height: rendered.size.height * canvasScale
            )
        }
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
      DragGesture(coordinateSpace: .named("previewCanvas"))
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
          let normalizedX = min(
            1,
            max(0, value.location.x / max(size.width, 1))
          )
          let normalizedY = min(
            1,
            max(0, value.location.y / max(size.height, 1))
          )
          if item.kind == .caption {
            project.setCaptionPosition(
              normalizedX: normalizedX,
              normalizedY: normalizedY
            )
          } else {
            project.overlays[index].normalizedX = normalizedX
            project.overlays[index].normalizedY = normalizedY
          }
        }
        .onEnded { _ in
          draggingOverlayID = nil
        }
    )
  }

  private func fittedCanvasSize(in container: CGSize) -> CGSize {
    let canvas = project.canvas.size
    let scale = min(
      container.width / max(canvas.width, 1),
      container.height / max(canvas.height, 1)
    )
    return CGSize(
      width: max(1, canvas.width * scale),
      height: max(1, canvas.height * scale)
    )
  }
}

extension CaptionFontWeight {
  var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .semibold: .semibold
    case .bold: .bold
    case .heavy: .heavy
    }
  }

  var nsWeight: NSFont.Weight {
    switch self {
    case .regular: .regular
    case .semibold: .semibold
    case .bold: .bold
    case .heavy: .heavy
    }
  }
}
