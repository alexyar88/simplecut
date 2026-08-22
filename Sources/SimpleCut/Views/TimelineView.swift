import AppKit
import SwiftUI

struct TimelineZoomScrollRequest: Equatable {
  let id: UUID
  let anchor: TimelineZoomAnchorGeometry
}

@MainActor
final class TimelineScrollCoordinator: NSObject, ObservableObject {
  @Published private(set) var offset: CGFloat = 0
  private weak var scrollView: NSScrollView?
  private var contentWidth: CGFloat = 0
  private var viewportWidth: CGFloat = 0

  func attach(
    to scrollView: NSScrollView,
    contentWidth: CGFloat,
    viewportWidth: CGFloat
  ) {
    if self.scrollView !== scrollView {
      NotificationCenter.default.removeObserver(self)
      self.scrollView = scrollView
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrollBoundsDidChange),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }
    self.contentWidth = contentWidth
    self.viewportWidth = viewportWidth
    updateOffset()
  }

  func zoomAnchor(
    pointerViewportX: CGFloat?,
    playheadProgress: CGFloat
  ) -> TimelineZoomAnchorGeometry {
    let anchor = TimelineInteractionGeometry.zoomAnchor(
      contentWidth: contentWidth,
      viewportWidth: viewportWidth,
      contentMinX: -nativeOffset,
      pointerViewportX: pointerViewportX,
      playheadProgress: playheadProgress
    )
    return anchor
  }

  func apply(
    request: TimelineZoomScrollRequest,
    contentWidth: CGFloat,
    viewportWidth: CGFloat
  ) -> Bool {
    guard let scrollView else { return false }
    self.contentWidth = contentWidth
    self.viewportWidth = viewportWidth
    let nextOffset = TimelineInteractionGeometry.zoomScrollOffset(
      anchor: request.anchor,
      contentWidth: contentWidth,
      viewportWidth: viewportWidth
    )
    let currentOrigin = scrollView.contentView.bounds.origin
    scrollView.contentView.scroll(
      to: NSPoint(x: nextOffset, y: currentOrigin.y)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    updateOffset()
    return abs(scrollView.contentView.bounds.origin.x - nextOffset) <= 0.5
  }

  private var nativeOffset: CGFloat {
    scrollView?.contentView.bounds.origin.x ?? offset
  }

  @objc private func scrollBoundsDidChange(_ notification: Notification) {
    updateOffset()
  }

  private func updateOffset() {
    let nextOffset = nativeOffset
    if abs(offset - nextOffset) > 0.01 {
      offset = nextOffset
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

struct TimelineView: View {
  @EnvironmentObject private var project: EditorProject
  let playback: PlaybackState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isTrimming = false
  @State private var zoomAtMagnificationStart: Double?
  @State private var zoomAnchorAtMagnificationStart: TimelineZoomAnchorGeometry?
  @State private var zoomScrollRequest: TimelineZoomScrollRequest?
  @StateObject private var scrollCoordinator = TimelineScrollCoordinator()
  @State private var activeTrimClipID: UUID?
  @State private var activeTrimEdge: TrimEdge?
  @State private var trimDragOffset: CGFloat = 0
  @State private var trimPixelsPerSecondAtStart: Double?
  @State private var activeOverlayID: UUID?
  @State private var activeOverlayEdge: TrimEdge?
  @State private var overlayDragOffset: CGFloat = 0
  @State private var hoveredClipID: UUID?
  @State private var hoveredTrimClipID: UUID?
  @State private var hoveredTrimEdge: TrimEdge?
  @State private var lastSkimmedFrame: Int?
  // Keep the pointer in viewport coordinates. Content coordinates change when
  // the scroll view zooms or scrolls, even if the mouse itself does not move.
  @State private var hoveredTimelineViewportX: CGFloat?
  @State private var draggedClipID: UUID?
  @State private var clipDropInsertionIndex: Int?
  @State private var clipReorderTranslation: CGFloat = 0
  private let maximumTimelineZoom = 64.0
  // Keep cuts visually separated without moving their edit coordinate. Video
  // and audio cards are inset symmetrically; waveform and trim guides below
  // continue to use the logical boundary at the center of this gap.
  private let clipGap: CGFloat = 10
  private let clipCornerRadius = EditorTheme.compactCornerRadius
  private let playheadSnapDistance: CGFloat = 7

  var body: some View {
    Group {
      if project.clips.isEmpty {
        emptyTimelineContent
      } else {
        timelineContent
      }
    }
    .padding(12)
    .background(EditorTheme.timeline)
  }

  private var emptyTimelineContent: some View {
    VStack(spacing: 8) {
      timeRuler
      VStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 8)
          .fill(EditorTheme.canvas)
          .overlay {
            Image(systemName: "timeline.selection")
              .font(.title2)
              .foregroundStyle(.tertiary)
          }
          .frame(height: 104)
        RoundedRectangle(cornerRadius: 7)
          .fill(EditorTheme.canvas)
          .frame(height: 38)
      }
      .frame(height: 150, alignment: .top)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Пустой таймлайн")
  }

  private var timelineContent: some View {
    let overlayKinds = OverlayKind.timelineKinds(for: project.overlays)
    let clipLayout = TimelineClipLayout.make(from: project.clips)
    return VStack(spacing: 8) {
      timeRuler
      GeometryReader { viewport in
        let contentWidth = max(
          viewport.size.width,
          viewport.size.width * project.timelineZoom
        )
        ScrollView(.horizontal) {
          VStack(spacing: 8) {
            timelineTickRuler(width: contentWidth)
            ForEach(overlayKinds, id: \.self) { kind in
              overlayTrack(kind: kind, width: contentWidth)
            }
            timelineTrack(
              in: CGSize(width: contentWidth, height: 104),
              clipLayout: clipLayout
            )
            audioTrack(width: contentWidth, clipLayout: clipLayout)
          }
          .frame(width: contentWidth)
          .contentShape(Rectangle())
          .help("Ведите указателем по таймлайну для быстрого просмотра")
          .background {
            TimelineZoomScrollController(
              coordinator: scrollCoordinator,
              request: zoomScrollRequest,
              contentWidth: contentWidth,
              viewportWidth: viewport.size.width
            )
          }
          .overlay(alignment: .topLeading) {
            TimelineGlobalPlayhead(
              playback: playback,
              duration: project.duration,
              contentWidth: contentWidth
            )
          }
        }
        .coordinateSpace(name: "timelineViewport")
        .scrollIndicators(.visible)
        .overlay {
          ZStack(alignment: .topLeading) {
            if let viewportX = hoveredTimelineViewportX, !isTrimming {
              TimelineViewportSkimmer(
                viewportX: viewportX,
                anchoredViewportX: playback.isPlaying || project.duration <= 0
                  ? nil
                  : contentWidth * playback.anchoredPlayhead / project.duration
                    - scrollCoordinator.offset,
                snapDistance: playheadSnapDistance
              )
            }
            TimelinePointerTrackingView(
              onMoved: { viewportX in
                hoveredTimelineViewportX = viewportX
                updateTimelinePointer(
                  viewportX: viewportX,
                  contentMinX: -scrollCoordinator.offset,
                  contentWidth: contentWidth
                )
              },
              onExited: {
                lastSkimmedFrame = nil
                hoveredTimelineViewportX = nil
                playback.timelineSkimmerTime = nil
              }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .simultaneousGesture(
          SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
              guard !isTrimming else { return }
              let contentX = TimelineInteractionGeometry.contentX(
                viewportX: value.location.x,
                contentMinX: -scrollCoordinator.offset
              )
              let time = TimelineInteractionGeometry.time(
                at: snappedTimelineX(contentX, width: contentWidth),
                width: contentWidth,
                duration: project.duration
              )
              project.seek(to: time)
            }
        )
        .simultaneousGesture(
          MagnificationGesture()
            .onChanged { magnification in
              let initialZoom =
                zoomAtMagnificationStart ?? project.timelineZoom
              if zoomAtMagnificationStart == nil {
                zoomAtMagnificationStart = initialZoom
                zoomAnchorAtMagnificationStart = currentZoomAnchor()
              }
              setTimelineZoom(
                min(
                  maximumTimelineZoom,
                  max(1, initialZoom * Double(magnification))
                ),
                anchor: zoomAnchorAtMagnificationStart
              )
            }
            .onEnded { _ in
              zoomAtMagnificationStart = nil
              zoomAnchorAtMagnificationStart = nil
            }
        )
        .onChange(of: project.timelineZoom) {
          if let viewportX = hoveredTimelineViewportX {
            updateTimelinePointer(
              viewportX: viewportX,
              contentMinX: -scrollCoordinator.offset,
              contentWidth: contentWidth
            )
          }
        }
        .onChange(of: scrollCoordinator.offset) {
          if let viewportX = hoveredTimelineViewportX {
            updateTimelinePointer(
              viewportX: viewportX,
              contentMinX: -scrollCoordinator.offset,
              contentWidth: contentWidth
            )
          }
        }
      }
      .frame(height: 180 + CGFloat(overlayKinds.count) * 42)
      .onDisappear {
        playback.timelineSkimmerTime = nil
      }
    }
  }

  private var timeRuler: some View {
    HStack {
      PlaybackTimestampLabel(playback: playback)
        .help(
          "←/→ — один кадр · ↑/↓ — соседний стык · Home/End — начало/конец"
        )
      Text("/")
        .foregroundStyle(.secondary)
      Text(project.duration.timestamp)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Spacer()
      Text(selectionSummary)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Button {
          adjustZoom(by: -0.5)
        } label: {
          Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(.plain)
        .disabled(project.clips.isEmpty || project.timelineZoom <= 1)
        .accessibilityLabel("Уменьшить масштаб")
        Slider(
          value: Binding(
            get: { project.timelineZoom },
            set: { setTimelineZoom($0) }
          ),
          in: 1...maximumTimelineZoom,
          step: 0.25
        )
        .frame(width: 130)
        .accessibilityLabel("Масштаб таймлайна")
        .accessibilityValue(
          String(format: "%.2g×", project.timelineZoom)
        )
        .accessibilityAdjustableAction { direction in
          adjustZoom(by: direction == .increment ? 0.25 : -0.25)
        }
        .disabled(project.clips.isEmpty)
        Button {
          adjustZoom(by: 0.5)
        } label: {
          Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(.plain)
        .disabled(
          project.clips.isEmpty
            || project.timelineZoom >= maximumTimelineZoom
        )
        .accessibilityLabel("Увеличить масштаб")
      }
      .help("Масштаб таймлайна")
    }
    .font(.caption)
  }

  private var selectionSummary: String {
    let selectedCount = project.selectedClipIDs.count
    if selectedCount > 0 {
      return "Выбрано: \(selectedCount) из \(project.clips.count)"
    }
    return "\(project.clips.count) фрагм."
  }

  private func timelineTickRuler(width: CGFloat) -> some View {
    let interval = majorTickInterval(for: width)
    let tickCount = max(1, Int(ceil(project.duration / interval)))
    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 5)
        .fill(EditorTheme.canvas.opacity(0.72))
      ForEach(0...tickCount, id: \.self) { index in
        let time = min(project.duration, Double(index) * interval)
        let x = width * time / max(project.duration, 0.01)
        VStack(alignment: .leading, spacing: 2) {
          Text(time.rulerTimestamp)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Rectangle()
            .fill(EditorTheme.separator)
            .frame(width: 1, height: 7)
        }
        .offset(x: min(x, max(0, width - 45)))
      }
    }
    .frame(width: width, height: 22)
    .accessibilityHidden(true)
  }

  private func majorTickInterval(for width: CGFloat) -> Double {
    let approximateCount = max(1, Double(width / 96))
    let requested = project.duration / approximateCount
    let intervals: [Double] = [
      0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30,
      60, 120, 300, 600, 900, 1_800, 3_600,
    ]
    return intervals.first(where: { $0 >= requested }) ?? 7_200
  }

  private func timelineTrack(
    in size: CGSize,
    clipLayout: [TimelineClipLayout]
  ) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 8)
        .fill(EditorTheme.canvas)
        .contentShape(Rectangle())
      clipBoundaries(in: size, clipLayout: clipLayout)
    }
    .frame(width: size.width, height: size.height)
    .coordinateSpace(name: "timelineClipTrack")
    .contentShape(Rectangle())
    .overlay(alignment: .topLeading) {
      clipDropIndicator(in: size)
    }
    .simultaneousGesture(
      SpatialTapGesture(coordinateSpace: .local)
        .onEnded { value in
          guard !isTrimming else { return }
          selectClipAndSeek(x: value.location.x, width: size.width)
        }
    )
  }

  private func clipBoundaries(
    in size: CGSize,
    clipLayout: [TimelineClipLayout]
  ) -> some View {
    return ZStack(alignment: .leading) {
      ForEach(clipLayout) { layout in
        let index = layout.index
        let clip = layout.clip
        let start = layout.start
        let rawWidth =
          project.duration > 0
          ? size.width * clip.duration / project.duration
          : 0
        let rawOffset =
          project.duration > 0
          ? size.width * start / project.duration
          : 0
        let trim = trimDrag(for: clip, at: index, in: size)
        let cardOffset =
          rawOffset + clipGap / 2 + trim.offset
        let cardWidth =
          max(2, rawWidth - clipGap + trim.width)
        positionedClip(
          clip: clip,
          index: index,
          start: start,
          width: cardWidth,
          thumbnailWidth: max(2, rawWidth - clipGap),
          offset: cardOffset,
          trackSize: size
        )
        trimPreviewBand(
          for: clip,
          at: index,
          baseOffset: rawOffset,
          baseWidth: max(2, rawWidth),
          trackSize: size,
          height: size.height - 4
        )
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }

  private func positionedClip(
    clip: VideoClip,
    index: Int,
    start: Double,
    width: CGFloat,
    thumbnailWidth: CGFloat,
    offset: CGFloat,
    trackSize: CGSize
  ) -> some View {
    interactiveClip(
      clip: clip,
      index: index,
      start: start,
      width: width,
      thumbnailWidth: thumbnailWidth,
      offset: offset,
      trackSize: trackSize
    )
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("timeline-clip-\(index + 1)")
    .accessibilityLabel("Фрагмент \(index + 1)")
    .accessibilityValue(
      "\(start.timestamp)–\((start + clip.duration).timestamp)"
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      project.selectClip(id: clip.id)
    }
    .accessibilityAction(named: "Разрезать посередине") {
      splitClipInMiddle(clip, start: start)
    }
    .accessibilityAction(named: "Переместить влево") {
      project.moveClip(id: clip.id, by: -1)
    }
    .accessibilityAction(named: "Переместить вправо") {
      project.moveClip(id: clip.id, by: 1)
    }
  }

  private func interactiveClip(
    clip: VideoClip,
    index: Int,
    start: Double,
    width: CGFloat,
    thumbnailWidth: CGFloat,
    offset: CGFloat,
    trackSize: CGSize
  ) -> some View {
    decoratedClip(
      clip: clip,
      index: index,
      width: width,
      thumbnailWidth: thumbnailWidth,
      trackSize: trackSize
    )
    .contentShape(Rectangle())
    .offset(
      x: offset + (draggedClipID == clip.id ? clipReorderTranslation : 0)
    )
    .scaleEffect(draggedClipID == clip.id ? 1.015 : 1)
    .opacity(draggedClipID == clip.id ? 0.9 : 1)
    .zIndex(draggedClipID == clip.id ? 10 : 0)
    .animation(
      reduceMotion ? nil : EditorTheme.quickAnimation,
      value: draggedClipID
    )
    .onHover { isHovered in
      if isHovered {
        hoveredClipID = clip.id
      } else if hoveredClipID == clip.id {
        hoveredClipID = nil
      }
    }
    .contextMenu {
      clipContextMenu(clip: clip, index: index, start: start)
    }
    .gesture(clipReorderGesture(for: clip, trackSize: trackSize))
    .help(
      "Фрагмент \(index + 1) · \(clip.duration.timestamp)\n"
        + "Нажмите, чтобы выбрать · перетащите, чтобы изменить порядок"
    )
  }

  private func decoratedClip(
    clip: VideoClip,
    index: Int,
    width: CGFloat,
    thumbnailWidth: CGFloat,
    trackSize: CGSize
  ) -> some View {
    let isSelected = project.isClipSelected(clip.id)
    let pixelsPerSecond = trackSize.width / max(project.duration, 0.01)
    let gapInset = clipGap / 2
    let trimHandleWidth = TimelineInteractionGeometry.trimHandleWidth(
      cardWidth: width,
      preferredWidth: 16,
      exteriorInset: gapInset
    )
    let trimInteractionWidth =
      TimelineInteractionGeometry.trimInteractionWidth(
        cardWidth: width,
        exteriorInset: gapInset
      )
    let shadowColor =
      isSelected ? EditorTheme.accent.opacity(0.34) : .black.opacity(0.28)
    return baseClipCard(
      clip: clip,
      index: index,
      width: width,
      thumbnailWidth: thumbnailWidth,
      trackSize: trackSize
    )
    // Adjacent trim hit regions meet at the logical edit point. There is no
    // arrow-cursor dead zone between the two resize cursors at a split.
    .overlay {
      HStack(spacing: 0) {
        trimHandle(
          clip: clip,
          edge: .leading,
          pixelsPerSecond: pixelsPerSecond,
          hitWidth: trimHandleWidth
        )
        Spacer(minLength: 0)
        trimHandle(
          clip: clip,
          edge: .trailing,
          pixelsPerSecond: pixelsPerSecond,
          hitWidth: trimHandleWidth
        )
      }
      .frame(
        width: trimInteractionWidth,
        height: trackSize.height - 4
      )
    }
    .overlay(alignment: .leading) {
      trimEdgeIndicator(for: clip, edge: .leading)
        .offset(x: -gapInset)
    }
    .overlay(alignment: .trailing) {
      trimEdgeIndicator(for: clip, edge: .trailing)
        .offset(x: gapInset)
    }
    .shadow(
      color: shadowColor,
      radius: isSelected ? 3 : (hoveredClipID == clip.id ? 3 : 1),
      y: 1
    )
    .brightness(hoveredClipID == clip.id ? 0.045 : 0)
    .animation(
      reduceMotion ? nil : EditorTheme.quickAnimation,
      value: hoveredClipID == clip.id
    )
    .animation(
      reduceMotion ? nil : EditorTheme.quickAnimation,
      value: isSelected
    )
  }

  private func baseClipCard(
    clip: VideoClip,
    index: Int,
    width: CGFloat,
    thumbnailWidth: CGFloat,
    trackSize: CGSize
  ) -> some View {
    clipCard(
      clip: clip,
      index: index,
      width: width,
      thumbnailWidth: thumbnailWidth,
      trackSize: trackSize
    )
    .foregroundStyle(.white)
    // Constrain the live trim preview before applying its background and mask.
    // Otherwise the original-width thumbnail can render past the dragged edge
    // and cover the next clip until the edit is committed. Pin the content to
    // its leading edge so the strip does not drift during a live trim.
    .frame(
      width: width,
      height: trackSize.height - 4,
      alignment: .leading
    )
    .background(
      EditorTheme.accent.opacity(
        project.isClipSelected(clip.id) ? 0.38 : 0.24
      ),
      in: RoundedRectangle(cornerRadius: clipCornerRadius)
    )
    .clipShape(RoundedRectangle(cornerRadius: clipCornerRadius))
  }

  @ViewBuilder
  private func clipDropIndicator(in size: CGSize) -> some View {
    if let draggedClipID,
      let sourceIndex = project.clips.firstIndex(where: {
        $0.id == draggedClipID
      }),
      let insertionIndex = clipDropInsertionIndex,
      TimelineReorderGeometry.destinationIndex(
        sourceIndex: sourceIndex,
        insertionIndex: insertionIndex,
        clipCount: project.clips.count
      ) != nil
    {
      let x = TimelineReorderGeometry.insertionX(
        for: insertionIndex,
        width: size.width,
        clipDurations: project.clips.map(\.duration)
      )
      ZStack(alignment: .top) {
        Rectangle()
          .fill(EditorTheme.selection)
          .frame(width: 3, height: size.height)
          .shadow(color: EditorTheme.selection.opacity(0.8), radius: 3)
        Image(systemName: "arrowtriangle.down.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(EditorTheme.selection)
          .offset(y: -2)
      }
      .frame(width: 9, height: size.height)
      .offset(x: min(max(0, x - 4.5), max(0, size.width - 9)))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private func clipReorderGesture(
    for clip: VideoClip,
    trackSize: CGSize
  ) -> some Gesture {
    DragGesture(
      minimumDistance: 5,
      coordinateSpace: .named("timelineClipTrack")
    )
    .onChanged { value in
      guard !isTrimming else { return }
      if draggedClipID == nil {
        project.selectClip(id: clip.id)
        draggedClipID = clip.id
      }
      guard draggedClipID == clip.id else { return }
      clipReorderTranslation = value.translation.width
      let isNearTrack = value.location.y >= -36
        && value.location.y <= trackSize.height + 36
      clipDropInsertionIndex = isNearTrack
        ? TimelineReorderGeometry.insertionIndex(
          at: value.location.x,
          width: trackSize.width,
          clipDurations: project.clips.map(\.duration)
        )
        : nil
    }
    .onEnded { value in
      guard draggedClipID == clip.id else { return }
      let insertionIndex = clipDropInsertionIndex
        ?? ((value.location.y >= -36
          && value.location.y <= trackSize.height + 36)
          ? TimelineReorderGeometry.insertionIndex(
            at: value.location.x,
            width: trackSize.width,
            clipDurations: project.clips.map(\.duration)
          )
          : nil)
      resetClipReorderGesture()
      guard let insertionIndex else { return }
      _ = withAnimation(reduceMotion ? nil : EditorTheme.softAnimation) {
        project.moveClip(
          id: clip.id,
          toInsertionIndex: insertionIndex
        )
      }
    }
  }

  private func resetClipReorderGesture() {
    draggedClipID = nil
    clipDropInsertionIndex = nil
    clipReorderTranslation = 0
  }

  @ViewBuilder
  private func clipContextMenu(
    clip: VideoClip,
    index: Int,
    start: Double
  ) -> some View {
    Button("Разрезать посередине") {
      splitClipInMiddle(clip, start: start)
    }
    Button("Объединить выбранные") {
      project.joinSelectedClips()
    }
    .disabled(!project.canJoinSelectedClips)
    Divider()
    Button("Переместить влево") {
      project.moveClip(id: clip.id, by: -1)
    }
    .disabled(index == 0)
    Button("Переместить вправо") {
      project.moveClip(id: clip.id, by: 1)
    }
    .disabled(index == project.clips.count - 1)
    Divider()
    Button("Удалить", role: .destructive) {
      if !project.isClipSelected(clip.id) {
        project.selectClip(id: clip.id)
      }
      project.deleteSelectedClips()
    }
  }

  private func selectClip(
    _ clip: VideoClip
  ) {
    focusTimeline()
    let modifiers = NSEvent.modifierFlags
    project.selectClip(
      id: clip.id,
      extending: modifiers.contains(.command),
      range: modifiers.contains(.shift)
    )
  }

  private func selectClipAndSeek(x: CGFloat, width: CGFloat) {
    let snappedX = snappedTimelineX(x, width: width)
    let ratio = min(1, max(0, snappedX / max(width, 1)))
    let time = ratio * project.duration
    var cursor = 0.0
    if let clip = project.clips.enumerated().first(where: { index, clip in
      cursor += clip.duration
      let isLastClip = index == project.clips.index(before: project.clips.endIndex)
      return time < cursor || isLastClip
    })?.element {
      selectClip(clip)
    }
    project.seek(to: time)
  }

  private func focusTimeline() {
    NSApp.keyWindow?.makeFirstResponder(nil)
  }

  private func skimTimeline(at x: CGFloat, width: CGFloat) {
    guard !playback.isPlaying, !isTrimming, activeOverlayID == nil else {
      return
    }
    let time = TimelineInteractionGeometry.time(
      at: x,
      width: width,
      duration: project.duration
    )
    let frame = Int((time * 30).rounded(.down))
    let anchoredX = project.duration > 0
      ? width * playback.anchoredPlayhead / project.duration
      : 0
    let isSnappedToPlayhead = abs(x - anchoredX) < 0.5
    guard frame != lastSkimmedFrame
      || (isSnappedToPlayhead
        && abs(playback.playhead - playback.anchoredPlayhead) > 0.0001)
    else { return }
    lastSkimmedFrame = frame
    let scrubTime = isSnappedToPlayhead
      ? playback.anchoredPlayhead
      : min(project.duration, Double(frame) / 30)
    project.scrub(to: scrubTime)
  }

  private func updateTimelinePointer(
    viewportX: CGFloat,
    contentMinX: CGFloat,
    contentWidth: CGFloat
  ) {
    let contentX = timelineContentX(
      viewportX: viewportX,
      contentMinX: contentMinX,
      contentWidth: contentWidth
    )
    let snappedX = snappedTimelineX(contentX, width: contentWidth)
    playback.timelineSkimmerTime = TimelineInteractionGeometry.time(
      at: snappedX,
      width: contentWidth,
      duration: project.duration
    )
    skimTimeline(at: snappedX, width: contentWidth)
  }

  private func timelineContentX(
    viewportX: CGFloat,
    contentMinX: CGFloat,
    contentWidth: CGFloat
  ) -> CGFloat {
    let contentX = TimelineInteractionGeometry.contentX(
      viewportX: viewportX,
      contentMinX: contentMinX
    )
    return min(max(0, contentX), contentWidth)
  }

  private func snappedTimelineX(_ x: CGFloat, width: CGFloat) -> CGFloat {
    let clampedX = min(max(0, x), max(0, width))
    guard !playback.isPlaying, project.duration > 0 else { return clampedX }
    let anchoredX = width * playback.anchoredPlayhead / project.duration
    return TimelineInteractionGeometry.snappedX(
      clampedX,
      targetX: anchoredX,
      threshold: playheadSnapDistance
    )
  }

  private func adjustZoom(by delta: Double) {
    setTimelineZoom(
      min(maximumTimelineZoom, max(1, project.timelineZoom + delta))
    )
  }

  private func currentZoomAnchor() -> TimelineZoomAnchorGeometry {
    let playheadProgress = project.duration > 0
      ? CGFloat(playback.anchoredPlayhead / project.duration)
      : 0
    return scrollCoordinator.zoomAnchor(
      pointerViewportX: hoveredTimelineViewportX,
      playheadProgress: playheadProgress
    )
  }

  private func setTimelineZoom(
    _ zoom: Double,
    anchor: TimelineZoomAnchorGeometry? = nil
  ) {
    let clampedZoom = min(maximumTimelineZoom, max(1, zoom))
    guard abs(clampedZoom - project.timelineZoom) > 0.000_001 else { return }
    zoomScrollRequest = TimelineZoomScrollRequest(
      id: UUID(),
      anchor: anchor ?? currentZoomAnchor()
    )
    project.timelineZoom = clampedZoom
  }

  private func splitClipInMiddle(_ clip: VideoClip, start: Double) {
    project.selectClip(id: clip.id)
    project.seek(to: start + clip.duration / 2)
    project.splitAtPlayhead()
  }

  private func clipCard(
    clip: VideoClip,
    index: Int,
    width: CGFloat,
    thumbnailWidth: CGFloat,
    trackSize: CGSize
  ) -> some View {
    let isSelected = project.isClipSelected(clip.id)
    let thumbnailAdjustment = trimDrag(
      for: clip,
      at: index,
      in: trackSize
    )
    return ZStack(alignment: .leading) {
      ClipThumbnailStrip(clip: clip, width: thumbnailWidth)
        .frame(width: thumbnailWidth)
        .offset(
          x: activeTrimClipID == clip.id
            ? TimelineInteractionGeometry.thumbnailOffset(
              for: activeTrimEdge,
              adjustment: thumbnailAdjustment
            )
            : 0
        )
      LinearGradient(
        colors: [
          Color.black.opacity(0.05),
          Color.black.opacity(0.34),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      if isSelected {
        EditorTheme.accent.opacity(0.10)
          .allowsHitTesting(false)
      }
      clipMetadata(clip: clip, index: index, width: width)

      if activeTrimClipID == clip.id {
        VStack {
          Text(
            "Длина \(trimPreviewDuration(for: clip, in: trackSize).timestamp)"
          )
          .font(.caption2.bold().monospacedDigit())
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.black.opacity(0.72), in: Capsule())
          .padding(.top, 6)
          Spacer()
        }
        .allowsHitTesting(false)
      }
      RoundedRectangle(cornerRadius: clipCornerRadius)
        .strokeBorder(
          isSelected ? EditorTheme.accent : Color.white.opacity(0.22),
          lineWidth: isSelected ? 1.5 : 0.75
        )
        .allowsHitTesting(false)
    }
  }

  private func clipMetadata(
    clip: VideoClip,
    index: Int,
    width: CGFloat
  ) -> some View {
    Group {
      if TimelineInteractionGeometry.showsClipIndex(width: width) {
        VStack {
          Spacer()
          HStack(spacing: 5) {
            Text("\(index + 1)")
              .font(.caption2.bold())
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(.black.opacity(0.62), in: Capsule())
            Spacer(minLength: 0)
            if TimelineInteractionGeometry.showsClipDuration(width: width) {
              Text(clip.duration.timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            }
          }
          .padding(7)
        }
      }
    }
    .allowsHitTesting(false)
  }

  private func trimDrag(
    for clip: VideoClip,
    at index: Int,
    in size: CGSize
  ) -> TrimPreviewAdjustment {
    guard let activeTrimClipID, let activeTrimEdge,
      let activeIndex = project.clips.firstIndex(where: {
        $0.id == activeTrimClipID
      })
    else {
      return TrimPreviewAdjustment(offset: 0, width: 0)
    }
    guard index == activeIndex else {
      return TrimPreviewAdjustment(offset: 0, width: 0)
    }
    let pixelsPerSecond = size.width / max(project.duration, 0.01)
    let activeClip = project.clips[activeIndex]
    let adjustment = TrimPreviewGeometry.adjustment(
      for: activeClip,
      edge: activeTrimEdge,
      translation: trimDragOffset,
      pixelsPerSecond: pixelsPerSecond
    )
    return adjustment
  }

  private func trimPreviewDuration(
    for clip: VideoClip,
    in size: CGSize
  ) -> Double {
    guard activeTrimClipID == clip.id, let activeTrimEdge else {
      return clip.duration
    }
    let pixelsPerSecond = size.width / max(project.duration, 0.01)
    guard let index = project.clips.firstIndex(where: { $0.id == clip.id }) else {
      return clip.duration
    }
    let drag = trimDrag(for: clip, at: index, in: size)
    switch activeTrimEdge {
    case .leading:
      return clip.duration + drag.width / pixelsPerSecond
    case .trailing:
      return clip.duration + drag.width / pixelsPerSecond
    }
  }

  @ViewBuilder
  private func trimPreviewBand(
    for clip: VideoClip,
    at index: Int,
    baseOffset: CGFloat,
    baseWidth: CGFloat,
    trackSize: CGSize,
    height: CGFloat
  ) -> some View {
    if activeTrimClipID == clip.id, let activeTrimEdge {
      let adjustment = trimDrag(for: clip, at: index, in: trackSize)
      let delta =
        activeTrimEdge == .leading
        ? adjustment.offset
        : adjustment.width
      let originalEdge =
        activeTrimEdge == .leading
        ? baseOffset
        : baseOffset + baseWidth
      let previewEdge = originalEdge + delta
      let bandWidth = abs(delta)
      let isTemporaryGap =
        (activeTrimEdge == .leading && delta > 0)
        || (activeTrimEdge == .trailing && delta < 0)
      if bandWidth > 0.5 {
        ZStack(alignment: .leading) {
          Rectangle()
            .fill(
              isTemporaryGap
                ? EditorTheme.canvas
                : EditorTheme.trimPreview.opacity(0.34)
            )
          if isTemporaryGap {
            Rectangle()
              .stroke(
                EditorTheme.trimPreview.opacity(0.72),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
              )
          } else {
            Rectangle()
              .fill(EditorTheme.trimPreview)
              .frame(width: 2)
              .offset(x: delta < 0 ? 0 : max(0, bandWidth - 2))
          }
        }
        .frame(width: bandWidth, height: height)
        .offset(x: min(originalEdge, previewEdge), y: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }

  private func trimHandle(
    clip: VideoClip,
    edge: TrimEdge,
    pixelsPerSecond: Double,
    hitWidth: CGFloat
  ) -> some View {
    TimelineTrimHandleView(
      edge: edge,
      onHoverChanged: { isHovered in
        if isHovered {
          hoveredTrimClipID = clip.id
          hoveredTrimEdge = edge
        } else if hoveredTrimClipID == clip.id && hoveredTrimEdge == edge {
          hoveredTrimClipID = nil
          hoveredTrimEdge = nil
        }
      },
      onDragChanged: { translation in
        if !isTrimming {
          project.selectClip(id: clip.id)
          isTrimming = true
          activeTrimClipID = clip.id
          activeTrimEdge = edge
          trimPixelsPerSecondAtStart = pixelsPerSecond
        }
        // Keep the ripple timeline unchanged while the pointer is down.
        // This moves the grabbed edge itself and exposes a temporary gap.
        trimDragOffset = translation
      },
      onDragEnded: { translation in
        let initialPixelsPerSecond =
          trimPixelsPerSecondAtStart ?? pixelsPerSecond
        let deltaSeconds = translation
          / max(initialPixelsPerSecond, 0.01)
        isTrimming = false
        activeTrimClipID = nil
        activeTrimEdge = nil
        trimDragOffset = 0
        trimPixelsPerSecondAtStart = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
          project.resizeClip(
            id: clip.id,
            edge: edge,
            by: deltaSeconds
          )
        }
      }
    )
      .frame(width: hitWidth)
      .frame(maxHeight: .infinity)
      .help(
        edge == .leading
          ? "Потяните край: вправо — обрезать, влево — вернуть исходник"
          : "Потяните край: влево — обрезать, вправо — вернуть исходник"
      )
      .accessibilityLabel(
        edge == .leading
          ? "Обрезать начало фрагмента"
          : "Обрезать конец фрагмента"
      )
      .accessibilityValue(clip.duration.timestamp)
      .accessibilityAction(named: "Обрезать на один кадр") {
        project.trimClip(
          id: clip.id,
          edge: edge,
          by: 1.0 / 30
        )
      }
  }

  @ViewBuilder
  private func trimEdgeIndicator(
    for clip: VideoClip,
    edge: TrimEdge
  ) -> some View {
    let isHovered = hoveredTrimClipID == clip.id && hoveredTrimEdge == edge
    let isActive = activeTrimClipID == clip.id && activeTrimEdge == edge
    if isHovered || isActive {
      Capsule()
        .fill(isActive ? Color.yellow : Color.white.opacity(0.92))
        .frame(width: 3, height: 44)
        .shadow(color: .black.opacity(0.7), radius: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private func audioTrack(
    width trackWidth: CGFloat,
    clipLayout: [TimelineClipLayout]
  ) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 7)
        .fill(EditorTheme.canvas)
      audioClipSegments(width: trackWidth, clipLayout: clipLayout)
      Canvas { context, canvas in
        drawAudioWaveform(
          context: &context,
          canvas: canvas,
          clipLayout: clipLayout
        )
      }
      audioTrimPreviewBands(width: trackWidth, clipLayout: clipLayout)
    }
    .frame(width: trackWidth, height: 38)
    .contentShape(Rectangle())
    .gesture(
      SpatialTapGesture(coordinateSpace: .local)
        .onEnded { value in
          selectClipAndSeek(x: value.location.x, width: trackWidth)
        }
    )
    .help(
      project.audio.normalizeLoudness
        ? "Нажмите для перемотки · жёлтый — лимитер, красный — пик выше 0 dB"
        : "Нажмите, чтобы переместить курсор"
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Аудиодорожка")
    .accessibilityValue(project.playhead.timestamp)
    .accessibilityAction(named: "Переместить на секунду назад") {
      project.seek(by: -1)
    }
    .accessibilityAction(named: "Переместить на секунду вперёд") {
      project.seek(by: 1)
    }
  }

  private func drawAudioWaveform(
    context: inout GraphicsContext,
    canvas: CGSize,
    clipLayout: [TimelineClipLayout]
  ) {
    guard !project.waveform.isEmpty, project.duration > 0 else { return }
    let samples = WaveformPresentation.displaySamples(
      from: project.waveform,
      settings: project.audio,
      targetSampleCount: max(2, Int(ceil(canvas.width * 2)))
    )
    guard !samples.isEmpty else { return }
    for layout in clipLayout {
      let clip = layout.clip
      let adjustment = trimDrag(
        for: clip,
        at: layout.index,
        in: CGSize(width: canvas.width, height: 34)
      )
      let geometry = TimelineWaveformGeometry.segment(
        timelineStart: layout.start,
        clipDuration: clip.duration,
        totalDuration: project.duration,
        trackWidth: canvas.width,
        visualGap: clipGap,
        sampleCount: samples.count,
        trimEdge: activeTrimClipID == clip.id ? activeTrimEdge : nil,
        adjustment: adjustment
      )
      drawAudioWaveformSegment(
        context: &context,
        samples: Array(samples[geometry.sampleRange]),
        frame: CGRect(
          x: geometry.waveformFrame.minX,
          y: 0,
          width: geometry.waveformFrame.width,
          height: canvas.height
        )
      )
    }
  }

  private func drawAudioWaveformSegment(
    context: inout GraphicsContext,
    samples: [WaveformPresentationSample],
    frame: CGRect
  ) {
    guard !samples.isEmpty, frame.width > 0 else { return }
    // Audio levels are magnitudes, so mirroring them around the center line
    // duplicates the same information. Anchor silence to the bottom and use
    // the full card height for a denser, more legible one-sided waveform.
    let baseline = frame.maxY - 2
    let maximumAmplitude = max(1, frame.height - 4)
    let step = frame.width / CGFloat(max(1, samples.count - 1))
    var envelopePath = Path()
    var limiterPath = Path()
    var clippingPath = Path()

    if let first = samples.first {
      let amplitude = CGFloat(first.level) * maximumAmplitude
      envelopePath.move(to: CGPoint(x: frame.minX, y: baseline - amplitude))
      for (index, sample) in samples.dropFirst().enumerated() {
        let x = frame.minX + CGFloat(index + 1) * step
        let amplitude = CGFloat(sample.level) * maximumAmplitude
        envelopePath.addLine(to: CGPoint(x: x, y: baseline - amplitude))
      }
      envelopePath.addLine(to: CGPoint(x: frame.maxX, y: baseline))
      envelopePath.addLine(to: CGPoint(x: frame.minX, y: baseline))
      envelopePath.closeSubpath()
    }

    for (index, sample) in samples.enumerated() {
      let x = frame.minX + CGFloat(index) * step
      let amplitude = CGFloat(sample.level) * maximumAmplitude
      if sample.reachesLimiter {
        let markerInset: CGFloat = sample.clipsWithoutLimiter ? 0 : 1
        limiterPath.move(
          to: CGPoint(x: x, y: baseline - amplitude + markerInset)
        )
        limiterPath.addLine(to: CGPoint(x: x, y: baseline - amplitude + 2.5))
      }
      if sample.clipsWithoutLimiter {
        clippingPath.move(to: CGPoint(x: x, y: baseline - amplitude))
        clippingPath.addLine(to: CGPoint(x: x, y: baseline - amplitude + 1))
      }
    }

    context.fill(
      envelopePath,
      with: .color(EditorTheme.audioWave.opacity(0.82))
    )
    var silencePath = Path()
    silencePath.move(to: CGPoint(x: frame.minX, y: baseline))
    silencePath.addLine(to: CGPoint(x: frame.maxX, y: baseline))
    context.stroke(
      silencePath,
      with: .color(EditorTheme.audioWave.opacity(0.7)),
      lineWidth: 0.75
    )
    let lineWidth = max(1, min(2, step * 0.65))
    context.stroke(
      limiterPath,
      with: .color(EditorTheme.audioWarning),
      lineWidth: lineWidth
    )
    context.stroke(
      clippingPath,
      with: .color(EditorTheme.audioClipping),
      lineWidth: lineWidth
    )

    if project.audio.normalizeLoudness {
      let ceiling = CGFloat(pow(10, project.audio.peakCeilingDB / 20))
      let limitOffset = maximumAmplitude * ceiling
      var ceilingPath = Path()
      ceilingPath.move(
        to: CGPoint(x: frame.minX, y: baseline - limitOffset)
      )
      ceilingPath.addLine(
        to: CGPoint(x: frame.maxX, y: baseline - limitOffset)
      )
      context.stroke(
        ceilingPath,
        with: .color(EditorTheme.audioWarning.opacity(0.38)),
        style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
      )
    }
  }

  private func audioClipSegments(
    width trackWidth: CGFloat,
    clipLayout: [TimelineClipLayout]
  ) -> some View {
    ZStack(alignment: .leading) {
      ForEach(clipLayout) { layout in
        let index = layout.index
        let clip = layout.clip
        let start = layout.start
        let segmentWidth = project.duration > 0
          ? trackWidth * clip.duration / project.duration
          : 0
        let x = project.duration > 0
          ? trackWidth * start / project.duration
          : 0
        let adjustment = trimDrag(
          for: clip,
          at: index,
          in: CGSize(width: trackWidth, height: 34)
        )
        RoundedRectangle(cornerRadius: clipCornerRadius)
          .fill(
            project.isClipSelected(clip.id)
              ? EditorTheme.audioBackgroundSelected
              : EditorTheme.audioBackground
          )
          .overlay {
            if project.isClipSelected(clip.id) {
              RoundedRectangle(cornerRadius: clipCornerRadius)
                .stroke(EditorTheme.accent.opacity(0.82), lineWidth: 1)
            }
          }
          .frame(
            width: max(1, segmentWidth - clipGap + adjustment.width),
            height: 34
          )
          .offset(x: x + clipGap / 2 + adjustment.offset)
      }
    }
  }

  private func audioTrimPreviewBands(
    width trackWidth: CGFloat,
    clipLayout: [TimelineClipLayout]
  ) -> some View {
    ZStack(alignment: .leading) {
      ForEach(clipLayout) { layout in
        let index = layout.index
        let clip = layout.clip
        let start = layout.start
        let segmentWidth = project.duration > 0
          ? trackWidth * clip.duration / project.duration
          : 0
        let x = project.duration > 0
          ? trackWidth * start / project.duration
          : 0
        trimPreviewBand(
          for: clip,
          at: index,
          baseOffset: x,
          baseWidth: max(1, segmentWidth),
          trackSize: CGSize(width: trackWidth, height: 34),
          height: 30
        )
      }
    }
    .allowsHitTesting(false)
  }

  private func overlayTrack(
    kind: OverlayKind,
    width trackWidth: CGFloat
  ) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 6)
        .fill(trackColor(for: kind).opacity(0.08))
      ForEach(project.overlays.filter { $0.kind == kind }) { item in
        overlayTrackItem(item, trackWidth: trackWidth)
      }
    }
    .frame(height: 34)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(trackTitle(for: kind))
  }

  private func overlayTrackItem(
    _ item: OverlayItem,
    trackWidth: CGFloat
  ) -> some View {
    let pixelsPerSecond = trackWidth / max(project.duration, 0.01)
    let width = project.duration > 0
      ? trackWidth * item.duration / project.duration
      : 0
    let x = project.duration > 0
      ? trackWidth * item.startTime / project.duration
      : 0
    let adjustment = overlayAdjustment(
      for: item,
      pixelsPerSecond: pixelsPerSecond
    )
    let adjustedWidth = max(2, width + adjustment.width)
    let trimHandleWidth = TimelineInteractionGeometry.trimHandleWidth(
      cardWidth: adjustedWidth,
      preferredWidth: 15,
      exteriorInset: 0
    )

    return RoundedRectangle(cornerRadius: 5)
      .fill(trackColor(for: item.kind))
      .overlay(alignment: .leading) {
        if adjustedWidth >= 36 {
          Text(layerTitle(item))
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
        }
      }
      .overlay {
        if project.selectedOverlayID == item.id {
          ZStack {
            RoundedRectangle(cornerRadius: 5)
              .stroke(Color.white, lineWidth: 2)
              .shadow(color: Color.accentColor, radius: 3)
            HStack(spacing: 0) {
              overlayTrimHandle(
                item: item,
                edge: .leading,
                pixelsPerSecond: pixelsPerSecond,
                hitWidth: trimHandleWidth
              )
              Spacer(minLength: 0)
              overlayTrimHandle(
                item: item,
                edge: .trailing,
                pixelsPerSecond: pixelsPerSecond,
                hitWidth: trimHandleWidth
              )
            }
          }
        }
      }
      .frame(width: adjustedWidth, height: 28)
      .contentShape(Rectangle().inset(by: -3))
      .gesture(overlayMoveGesture(for: item, pixelsPerSecond: pixelsPerSecond))
      .help(
        "\(layerTitle(item)) · \(item.startTime.timestamp) · \(item.duration.timestamp)"
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(layerTitle(item))
      .accessibilityValue(
        "\(item.startTime.timestamp), длительность \(item.duration.timestamp)"
      )
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        focusTimeline()
        project.selectOverlay(id: item.id, seekToStart: true)
      }
      .accessibilityAction(named: "Сдвинуть на 0,1 секунды влево") {
        project.recordUndoCheckpoint()
        project.moveOverlay(id: item.id, by: -0.1)
      }
      .accessibilityAction(named: "Сдвинуть на 0,1 секунды вправо") {
        project.recordUndoCheckpoint()
        project.moveOverlay(id: item.id, by: 0.1)
      }
      .position(
        x: x + adjustment.offset + adjustedWidth / 2,
        y: 17
      )
  }

  private func overlayMoveGesture(
    for item: OverlayItem,
    pixelsPerSecond: CGFloat
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { value in
        guard abs(value.translation.width) >= 3 else { return }
        activeOverlayID = item.id
        activeOverlayEdge = nil
        overlayDragOffset = value.translation.width
        project.clearClipSelection()
        project.selectedOverlayID = item.id
      }
      .onEnded { value in
        if abs(value.translation.width) < 3,
          abs(value.translation.height) < 3
        {
          focusTimeline()
          project.selectOverlay(id: item.id, seekToStart: true)
          resetOverlayGesture()
          return
        }
        let delta = clampedOverlayMove(
          item: item,
          requestedOffset: value.translation.width,
          pixelsPerSecond: pixelsPerSecond
        )
        if abs(delta) > 0.5 {
          project.recordUndoCheckpoint()
          project.moveOverlay(
            id: item.id,
            by: delta / max(pixelsPerSecond, 0.01)
          )
        }
        resetOverlayGesture()
      }
  }

  private func trackColor(for kind: OverlayKind) -> Color {
    switch kind {
    case .text: .purple
    case .caption: .blue
    case .image: .orange
    }
  }

  private func trackTitle(for kind: OverlayKind) -> String {
    switch kind {
    case .text: "Дорожка текста"
    case .caption: "Дорожка субтитров"
    case .image: "Дорожка изображений"
    }
  }

  private func overlayAdjustment(
    for item: OverlayItem,
    pixelsPerSecond: CGFloat
  ) -> (offset: CGFloat, width: CGFloat) {
    guard activeOverlayID == item.id else { return (0, 0) }
    if let activeOverlayEdge {
      let delta = clampedOverlayTrim(
        item: item,
        edge: activeOverlayEdge,
        requestedOffset: overlayDragOffset,
        pixelsPerSecond: pixelsPerSecond
      )
      return activeOverlayEdge == .leading
        ? (delta, -delta)
        : (0, delta)
    }
    return (
      clampedOverlayMove(
        item: item,
        requestedOffset: overlayDragOffset,
        pixelsPerSecond: pixelsPerSecond
      ),
      0
    )
  }

  private func clampedOverlayMove(
    item: OverlayItem,
    requestedOffset: CGFloat,
    pixelsPerSecond: CGFloat
  ) -> CGFloat {
    min(
      max(requestedOffset, -item.startTime * pixelsPerSecond),
      max(0, project.duration - item.startTime - item.duration)
        * pixelsPerSecond
    )
  }

  private func clampedOverlayTrim(
    item: OverlayItem,
    edge: TrimEdge,
    requestedOffset: CGFloat,
    pixelsPerSecond: CGFloat
  ) -> CGFloat {
    switch edge {
    case .leading:
      return min(
        max(requestedOffset, -item.startTime * pixelsPerSecond),
        max(0, item.duration - 0.1) * pixelsPerSecond
      )
    case .trailing:
      return min(
        max(requestedOffset, -max(0, item.duration - 0.1) * pixelsPerSecond),
        max(0, project.duration - item.startTime - item.duration)
          * pixelsPerSecond
      )
    }
  }

  private func overlayTrimHandle(
    item: OverlayItem,
    edge: TrimEdge,
    pixelsPerSecond: CGFloat,
    hitWidth: CGFloat
  ) -> some View {
    TimelineTrimHandleView(
      edge: edge,
      onHoverChanged: { _ in },
      onDragChanged: { translation in
        activeOverlayID = item.id
        activeOverlayEdge = edge
        overlayDragOffset = translation
      },
      onDragEnded: { translation in
        let delta = clampedOverlayTrim(
          item: item,
          edge: edge,
          requestedOffset: translation,
          pixelsPerSecond: pixelsPerSecond
        )
        if abs(delta) > 0.5 {
          project.recordUndoCheckpoint()
          project.resizeOverlay(
            id: item.id,
            edge: edge,
            by: delta / max(pixelsPerSecond, 0.01)
          )
        }
        resetOverlayGesture()
      }
    )
      .frame(width: hitWidth)
      .overlay {
        RoundedRectangle(cornerRadius: 2)
          .fill(.white)
          .frame(width: 7)
          .padding(.vertical, 3)
          .allowsHitTesting(false)
      }
      .help(
        edge == .leading
          ? "Изменить начало слоя"
          : "Изменить конец слоя"
      )
      .accessibilityLabel(
        edge == .leading
          ? "Начало слоя"
          : "Конец слоя"
      )
  }

  private func resetOverlayGesture() {
    activeOverlayID = nil
    activeOverlayEdge = nil
    overlayDragOffset = 0
  }

  private func layerTitle(_ item: OverlayItem) -> String {
    switch item.kind {
    case .text: item.text ?? "Текст"
    case .caption: item.text ?? "Субтитры"
    case .image: "Изображение"
    }
  }
}

/// Applies the exact horizontal offset after SwiftUI has laid out the wider
/// timeline. `ScrollViewReader` aligns dynamic background markers unreliably
/// on macOS, so cursor-anchored zoom uses the underlying scroll view directly.
private struct TimelineZoomScrollController: NSViewRepresentable {
  let coordinator: TimelineScrollCoordinator
  let request: TimelineZoomScrollRequest?
  let contentWidth: CGFloat
  let viewportWidth: CGFloat

  func makeNSView(context: Context) -> TimelineZoomScrollControllerNSView {
    TimelineZoomScrollControllerNSView()
  }

  func updateNSView(
    _ nsView: TimelineZoomScrollControllerNSView,
    context: Context
  ) {
    nsView.schedule(
      coordinator: coordinator,
      request: request,
      contentWidth: contentWidth,
      viewportWidth: viewportWidth
    )
  }
}

final class TimelineZoomScrollControllerNSView: NSView {
  private weak var coordinator: TimelineScrollCoordinator?
  private var appliedRequestID: UUID?
  private var latestContentWidth: CGFloat = 0
  private var latestViewportWidth: CGFloat = 0
  private var pendingRequest: (
    request: TimelineZoomScrollRequest,
    contentWidth: CGFloat,
    viewportWidth: CGFloat
  )?

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func schedule(
    coordinator: TimelineScrollCoordinator,
    request: TimelineZoomScrollRequest?,
    contentWidth: CGFloat,
    viewportWidth: CGFloat
  ) {
    self.coordinator = coordinator
    latestContentWidth = contentWidth
    latestViewportWidth = viewportWidth
    if let request, request.id != appliedRequestID {
      pendingRequest = (request, contentWidth, viewportWidth)
    }
    if let scrollView = enclosingScrollView {
      coordinator.attach(
        to: scrollView,
        contentWidth: contentWidth,
        viewportWidth: viewportWidth
      )
    }
    // Apply during the same SwiftUI update whenever the document already has
    // its new width. This prevents the enlarged content from being displayed
    // for one frame before the anchor correction.
    applyPendingRequest()
    guard pendingRequest != nil else { return }
    DispatchQueue.main.async { [weak self] in
      self?.applyPendingRequest()
    }
  }

  private func applyPendingRequest() {
    guard let coordinator, let scrollView = enclosingScrollView else { return }
    let metrics = pendingRequest.map {
      ($0.contentWidth, $0.viewportWidth)
    } ?? (latestContentWidth, latestViewportWidth)
    coordinator.attach(
      to: scrollView,
      contentWidth: metrics.0,
      viewportWidth: metrics.1
    )
    guard let pendingRequest else { return }
    let didApply = coordinator.apply(
      request: pendingRequest.request,
      contentWidth: pendingRequest.contentWidth,
      viewportWidth: pendingRequest.viewportWidth
    )
    guard didApply else { return }
    appliedRequestID = pendingRequest.request.id
    self.pendingRequest = nil
  }
}

/// Tracks pointer movement over the whole timeline independently from SwiftUI
/// hit testing. Child gestures (clip trims, captions, images, and text layers)
/// can therefore never starve the global skimmer of mouse-moved events.
private struct TimelinePointerTrackingView: NSViewRepresentable {
  let onMoved: (CGFloat) -> Void
  let onExited: () -> Void

  func makeNSView(context: Context) -> TimelinePointerTrackingNSView {
    let view = TimelinePointerTrackingNSView()
    view.onMoved = onMoved
    view.onExited = onExited
    return view
  }

  func updateNSView(
    _ nsView: TimelinePointerTrackingNSView,
    context: Context
  ) {
    nsView.onMoved = onMoved
    nsView.onExited = onExited
    // Zooming and rebuilding clips can move the view underneath a stationary
    // pointer without producing mouseMoved/mouseExited. Reconcile against the
    // window's actual pointer position after SwiftUI finishes this update.
    DispatchQueue.main.async { [weak nsView] in
      nsView?.refreshPointerLocation()
    }
  }
}

final class TimelinePointerTrackingNSView: NSView {
  var onMoved: ((CGFloat) -> Void)?
  var onExited: (() -> Void)?
  private var pointerTrackingArea: NSTrackingArea?
  private var lastPointerLocation: NSPoint?
  private var isPointerInside = false

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseEnteredAndExited,
        .mouseMoved,
        .activeInKeyWindow,
        .inVisibleRect,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
    refreshPointerLocation()
  }

  override func mouseEntered(with event: NSEvent) {
    reportPointerLocation(from: event)
  }

  override func mouseMoved(with event: NSEvent) {
    reportPointerLocation(from: event)
  }

  override func mouseExited(with event: NSEvent) {
    // Removing/replacing tracking areas during a split, zoom, or reorder can
    // deliver a stale exit after the replacement is already under the mouse.
    // Reconcile with the real pointer position instead of clearing the
    // skimmer from the stale event.
    refreshPointerLocation()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func reportPointerLocation(from event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    reportPointerLocation(location)
  }

  func refreshPointerLocation() {
    guard let window else {
      reportPointerExit()
      return
    }
    let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard bounds.contains(location) else {
      reportPointerExit()
      return
    }
    reportPointerLocation(location)
  }

  private func reportPointerLocation(_ location: NSPoint) {
    let x = min(max(0, location.x), bounds.width)
    let didMove = lastPointerLocation.map {
      abs($0.x - location.x) > 0.1 || abs($0.y - location.y) > 0.1
    } ?? true
    lastPointerLocation = location
    guard !isPointerInside || didMove else { return }
    isPointerInside = true
    onMoved?(x)
  }

  private func reportPointerExit() {
    lastPointerLocation = nil
    guard isPointerInside else { return }
    isPointerInside = false
    onExited?()
  }
}

/// Owns both pointer input and its cursor rectangle in AppKit. A split replaces
/// one instance with two fresh instances, so the new edges work immediately
/// without waiting for SwiftUI to rebuild hover state.
private struct TimelineTrimHandleView: NSViewRepresentable {
  let edge: TrimEdge
  let onHoverChanged: (Bool) -> Void
  let onDragChanged: (CGFloat) -> Void
  let onDragEnded: (CGFloat) -> Void

  func makeNSView(context: Context) -> TimelineTrimHandleNSView {
    let view = TimelineTrimHandleNSView()
    view.edge = edge
    view.onHoverChanged = onHoverChanged
    view.onDragChanged = onDragChanged
    view.onDragEnded = onDragEnded
    return view
  }

  func updateNSView(
    _ nsView: TimelineTrimHandleNSView,
    context: Context
  ) {
    nsView.edge = edge
    nsView.onHoverChanged = onHoverChanged
    nsView.onDragChanged = onDragChanged
    nsView.onDragEnded = onDragEnded
  }
}

final class TimelineTrimHandleNSView: NSView {
  var edge: TrimEdge = .leading
  var onHoverChanged: ((Bool) -> Void)?
  var onDragChanged: ((CGFloat) -> Void)?
  var onDragEnded: ((CGFloat) -> Void)?
  private var dragStartX: CGFloat?
  private var cursorTrackingArea: NSTrackingArea?
  private var pointerEventMonitor: Any?
  private var isHovering = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updatePointerEventMonitor()
    window?.invalidateCursorRects(for: self)
    refreshHoverState()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    window?.invalidateCursorRects(for: self)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTrackingArea {
      removeTrackingArea(cursorTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseEnteredAndExited,
        .mouseMoved,
        .cursorUpdate,
        .activeInKeyWindow,
        .inVisibleRect,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    cursorTrackingArea = area
    refreshHoverState()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseEntered(with event: NSEvent) {
    setHovering(true)
  }

  override func mouseMoved(with event: NSEvent) {
    setHovering(true)
  }

  override func cursorUpdate(with event: NSEvent) {
    setHovering(true)
  }

  override func mouseExited(with event: NSEvent) {
    // SwiftUI can replace or resize a representable while the pointer is
    // stationary. Resolve the real pointer position after that update instead
    // of immediately flashing the arrow cursor.
    DispatchQueue.main.async { [weak self] in
      self?.refreshHoverState()
    }
  }

  override func mouseDown(with event: NSEvent) {
    dragStartX = event.locationInWindow.x
    setHovering(true)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStartX else { return }
    // Keep the resize cursor while dragging outside the narrow hit region.
    NSCursor.resizeLeftRight.set()
    onDragChanged?(event.locationInWindow.x - dragStartX)
  }

  override func mouseUp(with event: NSEvent) {
    guard let dragStartX else { return }
    self.dragStartX = nil
    onDragEnded?(event.locationInWindow.x - dragStartX)
    window?.invalidateCursorRects(for: self)
    refreshHoverState()
  }

  func setHovering(_ hovering: Bool) {
    if hovering {
      NSCursor.resizeLeftRight.set()
    }
    guard isHovering != hovering else { return }
    isHovering = hovering
    onHoverChanged?(hovering)
  }

  private func refreshHoverState() {
    guard let window else {
      setHovering(false)
      return
    }
    let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let hovering = bounds.contains(location)
    setHovering(hovering)
    if !hovering {
      // Let AppKit choose the cursor from the complete cursor-rect stack.
      // Setting `.arrow` here lets a stale exit from the opposite edge
      // overwrite the resize cursor that has just entered this handle.
      window.invalidateCursorRects(for: self)
    }
  }

  /// Cursor rectangles from the enclosing SwiftUI scroll view can be resolved
  /// after this view's tracking callback, especially at the trailing edge of
  /// the last clip. Reconcile once more at the end of every pointer event so
  /// the deepest view under the pointer wins deterministically.
  private func updatePointerEventMonitor() {
    if let pointerEventMonitor {
      NSEvent.removeMonitor(pointerEventMonitor)
      self.pointerEventMonitor = nil
    }
    guard window != nil else { return }
    pointerEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged]
    ) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      let localLocation = self.convert(event.locationInWindow, from: nil)
      // Every trim handle receives the window-level monitor event. Scheduling
      // refreshes for handles that are not under the pointer invalidates their
      // cursor rectangles and makes the active handle visibly flicker between
      // arrow and resize. Only the single matching handle may reassert.
      guard self.bounds.contains(localLocation) else { return event }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.dragStartX != nil || self.isPointerActuallyInside
        else { return }
        self.setHovering(true)
      }
      return event
    }
  }

  private var isPointerActuallyInside: Bool {
    guard let window else { return false }
    let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return bounds.contains(location)
  }
}

private struct TimelineClipLayout: Identifiable {
  let index: Int
  let clip: VideoClip
  let start: Double

  var id: UUID { clip.id }

  static func make(from clips: [VideoClip]) -> [TimelineClipLayout] {
    var start = 0.0
    return clips.enumerated().map { index, clip in
      defer { start += clip.duration }
      return TimelineClipLayout(index: index, clip: clip, start: start)
    }
  }
}

private struct PlaybackTimestampLabel: View {
  @ObservedObject var playback: PlaybackState

  var body: some View {
    Text(playback.playhead.timestamp)
      .monospacedDigit()
  }
}

private struct TimelineGlobalPlayhead: View {
  @ObservedObject var playback: PlaybackState
  let duration: Double
  let contentWidth: CGFloat

  var body: some View {
    let playbackX = duration > 0
      ? contentWidth * playback.playhead / duration
      : 0
    let anchoredX = duration > 0
      ? contentWidth * playback.anchoredPlayhead / duration
      : 0
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        if !playback.isPlaying {
          Rectangle()
            .fill(Color.gray.opacity(0.58))
            .frame(width: 1, height: proxy.size.height)
            .offset(x: min(max(0, anchoredX - 0.5), contentWidth - 1))
        }
        if playback.isPlaying {
          Rectangle()
            .fill(Color.white.opacity(0.96))
            .frame(width: 1.5, height: proxy.size.height)
            .offset(x: min(max(0, playbackX - 0.75), contentWidth - 1.5))
            .shadow(color: .black.opacity(0.7), radius: 1)
          Image(systemName: "arrowtriangle.down.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.96))
            .shadow(color: .black.opacity(0.75), radius: 1)
            .offset(
              x: min(max(0, playbackX - 4.5), contentWidth - 9),
              y: 1
            )
        }
      }
      .frame(
        width: contentWidth,
        height: proxy.size.height,
        alignment: .topLeading
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

private struct TimelineViewportSkimmer: View {
  let viewportX: CGFloat
  let anchoredViewportX: CGFloat?
  let snapDistance: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let geometry = TimelineInteractionGeometry.viewportSkimmer(
        pointerViewportX: viewportX,
        anchoredViewportX: anchoredViewportX,
        viewportWidth: proxy.size.width,
        snapDistance: snapDistance
      )
      let x = geometry.x
      let color = geometry.isSnapped
        ? Color.yellow
        : Color.white.opacity(0.96)
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(color)
          .frame(width: 1.5, height: proxy.size.height)
          .offset(x: min(max(0, x - 0.75), max(0, proxy.size.width - 1.5)))
          .shadow(color: .black.opacity(0.7), radius: 1)
        Image(systemName: "arrowtriangle.down.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(color)
          .shadow(color: .black.opacity(0.75), radius: 1)
          .offset(
            x: min(max(0, x - 4.5), max(0, proxy.size.width - 9)),
            y: 1
          )
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

private struct ClipThumbnailStrip: View {
  let clip: VideoClip
  let width: CGFloat
  @State private var images: [CGImage] = []

  private let targetThumbnailWidth: CGFloat = 176

  private var imageCount: Int {
    let countForWidth = max(1, Int(ceil(width / targetThumbnailWidth)))
    let availableFrames = max(1, Int(ceil(clip.duration * 30)))
    return min(120, countForWidth, availableFrames)
  }

  var body: some View {
    GeometryReader { proxy in
      if images.isEmpty {
        ZStack {
          EditorTheme.accent.opacity(0.48)
          Image(systemName: "film")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.58))
        }
      } else {
        HStack(spacing: 1) {
          ForEach(Array(images.enumerated()), id: \.offset) { _, image in
            Image(decorative: image, scale: 1)
              .resizable()
              .scaledToFill()
              .frame(
                width: max(
                  1,
                  (proxy.size.width - CGFloat(imageCount - 1))
                    / CGFloat(imageCount)
                ),
                height: proxy.size.height,
                alignment: .center
              )
              .background(Color.black.opacity(0.3))
              .clipped()
          }
        }
        .frame(
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .leading
        )
      }
    }
    .task(id: thumbnailRequestID) {
      // A short debounce avoids starting a new decode for every tiny zoom step.
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      let requestedImages = await ClipThumbnailGenerator.images(
        for: clip,
        count: imageCount,
        height: 100
      )
      guard !Task.isCancelled else { return }
      images = requestedImages
    }
    .accessibilityHidden(true)
  }

  private var thumbnailRequestID: String {
    "\(clip.id.uuidString)-\(clip.sourceStart)-\(clip.duration)-\(imageCount)"
  }
}

private extension Double {
  var rulerTimestamp: String {
    guard isFinite else { return "0:00" }
    let value = max(0, self)
    if value < 60 {
      return value < 10 && value.rounded() != value
        ? String(format: "%.1f", value)
        : "\(Int(value))s"
    }
    let totalSeconds = Int(value)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}
