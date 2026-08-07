import AppKit
import SwiftUI

struct PreviewCanvas: View {
  @EnvironmentObject private var project: EditorProject
  @State private var draggingOverlayID: UUID?
  @State private var resizingOverlayID: UUID?
  @State private var resizeStartWidth: Double?
  @State private var resizeStartX: Double?

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

        ForEach(project.overlays.inCompositingOrder) { item in
          if project.playhead >= item.startTime,
            project.playhead <= item.startTime + item.duration
          {
            overlay(item, in: canvasSize)
          }
        }

        if let selectedOverlay = project.overlays.first(where: {
          $0.id == project.selectedOverlayID
        }),
          project.playhead >= selectedOverlay.startTime,
          project.playhead
            <= selectedOverlay.startTime + selectedOverlay.duration
        {
          selectedOverlayInteraction(selectedOverlay, in: canvasSize)
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .coordinateSpace(name: "previewCanvas")
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      .clipped()
    }
  }

  private func overlay(_ item: OverlayItem, in size: CGSize) -> some View {
    let width = max(90, size.width * item.normalizedWidth)
    let canvasScale = size.width / max(project.canvas.size.width, 1)
    return overlayContent(item, canvasScale: canvasScale)
      .frame(width: width)
      .opacity(item.opacity)
      .rotationEffect(.degrees(item.rotation))
      .contentShape(Rectangle())
      .onTapGesture {
        project.selectOverlay(id: item.id)
      }
      .gesture(overlayDragGesture(for: item, canvasSize: size))
      .position(
        x: size.width * item.normalizedX,
        y: size.height * item.normalizedY
      )
  }

  @ViewBuilder
  private func overlayContent(
    _ item: OverlayItem,
    canvasScale: CGFloat
  ) -> some View {
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

  private func selectedOverlayInteraction(
    _ item: OverlayItem,
    in size: CGSize
  ) -> some View {
    let width = max(90, size.width * item.normalizedWidth)
    let canvasScale = size.width / max(project.canvas.size.width, 1)
    return overlayContent(item, canvasScale: canvasScale)
      .frame(width: width)
      .opacity(0.001)
      .rotationEffect(.degrees(item.rotation))
      .overlay {
        GeometryReader { bounds in
          ZStack {
            RoundedRectangle(cornerRadius: 5)
              .stroke(
                .blue,
                style: StrokeStyle(lineWidth: 2, dash: [5])
              )
            resizeHandle(
              item: item,
              edge: .leading,
              canvasSize: size
            )
            .position(x: 0, y: 0)
            resizeHandle(
              item: item,
              edge: .trailing,
              canvasSize: size
            )
            .position(x: bounds.size.width, y: 0)
            resizeHandle(
              item: item,
              edge: .leading,
              canvasSize: size
            )
            .position(x: 0, y: bounds.size.height)
            resizeHandle(
              item: item,
              edge: .trailing,
              canvasSize: size
            )
            .position(x: bounds.size.width, y: bounds.size.height)
          }
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        project.selectOverlay(id: item.id)
      }
      .gesture(overlayDragGesture(for: item, canvasSize: size))
      .accessibilityHidden(true)
      .position(
        x: size.width * item.normalizedX,
        y: size.height * item.normalizedY
      )
  }

  private func overlayDragGesture(
    for item: OverlayItem,
    canvasSize size: CGSize
  ) -> some Gesture {
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
  }

  private func resizeHandle(
    item: OverlayItem,
    edge: OverlayResizeEdge,
    canvasSize: CGSize
  ) -> some View {
    Circle()
      .fill(.white)
      .overlay {
        Circle()
          .stroke(.blue, lineWidth: 2)
      }
      .frame(width: 11, height: 11)
      .contentShape(Rectangle().inset(by: -7))
      .highPriorityGesture(
        DragGesture(coordinateSpace: .named("previewCanvas"))
          .onChanged { value in
            guard
              let current = project.overlays.first(where: {
                $0.id == item.id
              })
            else { return }
            if resizingOverlayID != item.id {
              project.recordUndoCheckpoint()
              resizingOverlayID = item.id
              resizeStartWidth = current.normalizedWidth
              resizeStartX = current.normalizedX
            }
            guard
              let startWidth = resizeStartWidth,
              let startX = resizeStartX
            else { return }
            project.selectedOverlayID = item.id
            let direction = edge == .trailing ? 1.0 : -1.0
            let requestedWidth =
              startWidth
              + direction * value.translation.width
                / max(canvasSize.width, 1)
            let width = min(1, max(0.1, requestedWidth))
            let widthDelta = width - startWidth
            let requestedX = startX + direction * widthDelta / 2
            let x = min(
              1 - width / 2,
              max(width / 2, requestedX)
            )
            project.setOverlayWidth(
              id: item.id,
              normalizedWidth: width
            )
            if item.kind == .caption {
              project.setCaptionPosition(
                normalizedX: x,
                normalizedY: current.normalizedY
              )
            } else if let index = project.overlays.firstIndex(where: {
              $0.id == item.id
            }) {
              project.overlays[index].normalizedX = x
            }
          }
          .onEnded { _ in
            resizingOverlayID = nil
            resizeStartWidth = nil
            resizeStartX = nil
          }
      )
      .onContinuousHover { phase in
        switch phase {
        case .active:
          NSCursor.resizeLeftRight.set()
        case .ended:
          NSCursor.arrow.set()
        }
      }
      .help("Потяните, чтобы изменить размер")
      .accessibilityLabel("Изменить размер слоя")
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

private enum OverlayResizeEdge {
  case leading
  case trailing
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
