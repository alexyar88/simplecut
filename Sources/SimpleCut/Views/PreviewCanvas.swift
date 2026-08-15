import AppKit
import SwiftUI

struct PreviewCanvas: View {
  @EnvironmentObject private var project: EditorProject
  @ObservedObject var playback: PlaybackState
  @AppStorage("SimpleCut.preview.socialSafeArea")
  private var showsSocialSafeArea = true
  @State private var draggingOverlayID: UUID?
  @State private var resizingOverlayID: UUID?
  @State private var resizeStartWidth: Double?
  @State private var resizeStartX: Double?

  var body: some View {
    GeometryReader { proxy in
      let canvasSize = fittedCanvasSize(in: proxy.size)
      ZStack {
        Color.black
        PlayerView(
          player: project.player,
          scalingMode: project.scalingMode,
          color: project.color
        )

        if showsSocialSafeArea,
          let safeArea = project.canvas.socialSafeArea
        {
          socialSafeAreaOverlay(safeArea, canvasSize: canvasSize)
        }

        alignmentGuides(in: canvasSize)

        ForEach(project.overlays.inCompositingOrder) { item in
          if playback.playhead >= item.startTime,
            playback.playhead <= item.startTime + item.duration
          {
            overlay(item, in: canvasSize)
          }
        }

        if let selectedOverlay = project.overlays.first(where: {
          $0.id == project.selectedOverlayID
        }),
          playback.playhead >= selectedOverlay.startTime,
          playback.playhead
            <= selectedOverlay.startTime + selectedOverlay.duration
        {
          selectedOverlayInteraction(selectedOverlay, in: canvasSize)
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .coordinateSpace(name: "previewCanvas")
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      .clipped()
      .overlay {
        Rectangle()
          .stroke(.white.opacity(0.1), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.5), radius: 22, y: 8)
      .overlay(alignment: .topTrailing) {
        if project.canvas == .vertical {
          Button {
            showsSocialSafeArea.toggle()
          } label: {
            Image(
              systemName: showsSocialSafeArea
                ? "rectangle.dashed.badge.record"
                : "rectangle.dashed"
            )
          }
          .buttonStyle(.borderless)
          .padding(8)
          .help(
            showsSocialSafeArea
              ? "Скрыть безопасную зону соцсетей"
              : "Показать безопасную зону соцсетей"
          )
        }
      }
    }
  }

  private func socialSafeAreaOverlay(
    _ normalizedRect: CGRect,
    canvasSize: CGSize
  ) -> some View {
    let rect = CGRect(
      x: normalizedRect.minX * canvasSize.width,
      y: normalizedRect.minY * canvasSize.height,
      width: normalizedRect.width * canvasSize.width,
      height: normalizedRect.height * canvasSize.height
    )
    return RoundedRectangle(cornerRadius: 6)
      .stroke(
        Color.white.opacity(0.55),
        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
      )
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func alignmentGuides(in size: CGSize) -> some View {
    if let draggingOverlayID,
      let item = project.overlays.first(where: { $0.id == draggingOverlayID })
    {
      if abs(item.normalizedX - 0.5) < 0.0001 {
        Rectangle()
          .fill(EditorTheme.selection.opacity(0.85))
          .frame(width: 1, height: size.height)
          .allowsHitTesting(false)
      }
      if abs(item.normalizedY - 0.5) < 0.0001 {
        Rectangle()
          .fill(EditorTheme.selection.opacity(0.85))
          .frame(width: size.width, height: 1)
          .allowsHitTesting(false)
      }
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
      .onContinuousHover { phase in
        switch phase {
        case .active:
          NSCursor.openHand.set()
        case .ended:
          NSCursor.arrow.set()
        }
      }
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
        let image = PreviewAssetCache.image(at: url)
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
          NSCursor.closedHand.set()
        }
        project.selectedOverlayID = item.id
        let requestedX = min(
          1,
          max(0, value.location.x / max(size.width, 1))
        )
        let requestedY = min(
          1,
          max(0, value.location.y / max(size.height, 1))
        )
        let snapDistance = 8 / max(min(size.width, size.height), 1)
        let normalizedX = abs(requestedX - 0.5) <= snapDistance
          ? 0.5 : requestedX
        let normalizedY = abs(requestedY - 0.5) <= snapDistance
          ? 0.5 : requestedY
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
        NSCursor.openHand.set()
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
