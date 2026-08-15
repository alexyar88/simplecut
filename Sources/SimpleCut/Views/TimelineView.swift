import AppKit
import SwiftUI

struct TimelineView: View {
  @EnvironmentObject private var project: EditorProject
  let playback: PlaybackState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isTrimming = false
  @State private var zoomAtMagnificationStart: Double?
  @State private var activeTrimClipID: UUID?
  @State private var activeTrimEdge: TrimEdge?
  @State private var trimDragOffset: CGFloat = 0
  @State private var trimPixelsPerSecondAtStart: Double?
  @State private var activeOverlayID: UUID?
  @State private var activeOverlayEdge: TrimEdge?
  @State private var overlayDragOffset: CGFloat = 0
  @State private var hoveredClipID: UUID?
  @State private var lastSkimmedFrame: Int?
  @State private var hoveredTimelineX: CGFloat?
  @State private var timelineContentMinX: CGFloat = 0
  private let maximumTimelineZoom = 64.0
  private let clipGap: CGFloat = 10
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
            GeometryReader { content in
              Color.clear.preference(
                key: TimelineContentMinXPreferenceKey.self,
                value: content.frame(in: .named("timelineViewport")).minX
              )
            }
          }
          .overlay(alignment: .topLeading) {
            TimelineGlobalPlayhead(
              playback: playback,
              duration: project.duration,
              contentWidth: contentWidth,
              hoveredX: hoveredTimelineX,
              snapDistance: playheadSnapDistance
            )
          }
        }
        .coordinateSpace(name: "timelineViewport")
        .scrollIndicators(.visible)
        .onPreferenceChange(TimelineContentMinXPreferenceKey.self) { minX in
          timelineContentMinX = minX
        }
        .overlay {
          TimelinePointerTrackingView(
            onMoved: { viewportX in
              let contentX = TimelineInteractionGeometry.contentX(
                viewportX: viewportX,
                contentMinX: timelineContentMinX
              )
              let clampedX = min(max(0, contentX), contentWidth)
              hoveredTimelineX = clampedX
              skimTimeline(
                at: snappedTimelineX(clampedX, width: contentWidth),
                width: contentWidth
              )
            },
            onExited: {
              lastSkimmedFrame = nil
              hoveredTimelineX = nil
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .simultaneousGesture(
          SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
              guard !isTrimming else { return }
              let contentX = TimelineInteractionGeometry.contentX(
                viewportX: value.location.x,
                contentMinX: timelineContentMinX
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
              }
              project.timelineZoom = min(
                maximumTimelineZoom,
                max(1, initialZoom * Double(magnification))
              )
            }
            .onEnded { _ in
              zoomAtMagnificationStart = nil
            }
        )
      }
      .frame(height: 180 + CGFloat(overlayKinds.count) * 42)
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
          value: $project.timelineZoom,
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
    .contentShape(Rectangle())
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
          baseOffset: rawOffset + clipGap / 2,
          baseWidth: max(2, rawWidth - clipGap),
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
    let isSelected = project.isClipSelected(clip.id)
    let shadowColor =
      isSelected ? Color.accentColor.opacity(0.34) : .black.opacity(0.28)
    return clipCard(
      clip: clip,
      index: index,
      width: width,
      thumbnailWidth: thumbnailWidth,
      trackSize: trackSize
    )
    .foregroundStyle(.white)
    .background(
      Color(nsColor: .controlAccentColor).opacity(isSelected ? 0.38 : 0.24),
      in: RoundedRectangle(cornerRadius: 9)
    )
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .shadow(
      color: shadowColor,
      radius: isSelected ? 3 : (hoveredClipID == clip.id ? 3 : 1),
      y: 1
    )
    .brightness(hoveredClipID == clip.id ? 0.045 : 0)
    .offset(y: hoveredClipID == clip.id && !isTrimming ? -1 : 0)
    .animation(
      reduceMotion ? nil : EditorTheme.quickAnimation,
      value: hoveredClipID == clip.id
    )
    .animation(
      reduceMotion ? nil : EditorTheme.quickAnimation,
      value: isSelected
    )
    .frame(width: width, height: trackSize.height - 4)
    .contentShape(Rectangle())
    .offset(x: offset)
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
    project.timelineZoom = min(
      maximumTimelineZoom,
      max(1, project.timelineZoom + delta)
    )
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
    let pixelsPerSecond =
      trackSize.width / max(project.duration, 0.01)
    let thumbnailAdjustment = trimDrag(
      for: clip,
      at: index,
      in: trackSize
    )
    return ZStack(alignment: .leading) {
      ClipThumbnailStrip(clip: clip, width: thumbnailWidth)
        .frame(width: thumbnailWidth)
        .offset(
          x: activeTrimClipID == clip.id && activeTrimEdge == .leading
            ? -thumbnailAdjustment.offset
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
      clipMetadata(clip: clip, index: index, width: width)

      // Keep the invisible edge hit areas alive for every clip. Creating them
      // only after hover meant a newly split clip could miss the cursor event.
      HStack {
        trimHandle(
          clip: clip,
          edge: .leading,
          pixelsPerSecond: pixelsPerSecond
        )
        Spacer(minLength: 0)
        trimHandle(
          clip: clip,
          edge: .trailing,
          pixelsPerSecond: pixelsPerSecond
        )
      }
      .zIndex(2)
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
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(
          isSelected ? Color.accentColor : Color.white.opacity(0.22),
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
    VStack {
      Spacer()
      HStack(spacing: 5) {
        Text("\(index + 1)")
          .font(.caption2.bold())
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.black.opacity(0.58), in: Capsule())
        if width >= 76 {
          Text(clip.duration.timestamp)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.92))
        }
        Spacer(minLength: 0)
      }
      .padding(7)
    }
  }

  private func trimDrag(
    for clip: VideoClip,
    at index: Int,
    in size: CGSize
  ) -> (offset: CGFloat, width: CGFloat) {
    guard let activeTrimClipID, let activeTrimEdge,
      let activeIndex = project.clips.firstIndex(where: {
        $0.id == activeTrimClipID
      })
    else {
      return (0, 0)
    }
    guard index == activeIndex else { return (0, 0) }
    let pixelsPerSecond = size.width / max(project.duration, 0.01)
    let activeClip = project.clips[activeIndex]
    let adjustment = TrimPreviewGeometry.adjustment(
      for: activeClip,
      edge: activeTrimEdge,
      translation: trimDragOffset,
      pixelsPerSecond: pixelsPerSecond
    )
    return (adjustment.offset, adjustment.width)
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
    pixelsPerSecond: Double
  ) -> some View {
    Color.clear
      .frame(width: 12)
      .contentShape(Rectangle().inset(by: -3))
      .highPriorityGesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            if !isTrimming {
              project.selectClip(id: clip.id)
              isTrimming = true
              activeTrimClipID = clip.id
              activeTrimEdge = edge
              trimPixelsPerSecondAtStart = pixelsPerSecond
            }
            // Keep the ripple timeline unchanged while the pointer is down.
            // This moves the grabbed edge itself and exposes a temporary gap.
            trimDragOffset = value.translation.width
          }
          .onEnded { value in
            let initialPixelsPerSecond =
              trimPixelsPerSecondAtStart ?? pixelsPerSecond
            let deltaSeconds = value.translation.width
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
      .onContinuousHover { phase in
        switch phase {
        case .active:
          NSCursor.resizeLeftRight.set()
        case .ended:
          NSCursor.arrow.set()
        }
      }
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

  private func audioTrack(
    width trackWidth: CGFloat,
    clipLayout: [TimelineClipLayout]
  ) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 7)
        .fill(EditorTheme.canvas)
      audioClipSegments(width: trackWidth, clipLayout: clipLayout)
      Canvas { context, canvas in
        guard !project.waveform.isEmpty else { return }
        let samples = WaveformPresentation.displaySamples(
          from: project.waveform,
          settings: project.audio,
          targetSampleCount: max(2, Int(ceil(canvas.width * 2)))
        )
        let center = canvas.height / 2
        let maximumAmplitude = max(1, center - 2)
        let step = canvas.width / CGFloat(max(1, samples.count - 1))
        var envelopePath = Path()
        var limiterPath = Path()
        var clippingPath = Path()
        if let first = samples.first {
          let firstAmplitude = CGFloat(first.level) * maximumAmplitude
          envelopePath.move(
            to: CGPoint(x: 0, y: center - firstAmplitude)
          )
          for (index, sample) in samples.dropFirst().enumerated() {
            let x = CGFloat(index + 1) * step
            let amplitude = CGFloat(sample.level) * maximumAmplitude
            envelopePath.addLine(to: CGPoint(x: x, y: center - amplitude))
          }
          for index in samples.indices.reversed() {
            let x = CGFloat(index) * step
            let amplitude = CGFloat(samples[index].level) * maximumAmplitude
            envelopePath.addLine(to: CGPoint(x: x, y: center + amplitude))
          }
          envelopePath.closeSubpath()
        }
        for (index, sample) in samples.enumerated() {
          let x = CGFloat(index) * step
          let amplitude = CGFloat(sample.level) * maximumAmplitude
          if sample.reachesLimiter {
            let markerInset: CGFloat = sample.clipsWithoutLimiter ? 0 : 1
            limiterPath.move(to: CGPoint(x: x, y: center - amplitude + markerInset))
            limiterPath.addLine(to: CGPoint(x: x, y: center - amplitude + 2.5))
            limiterPath.move(to: CGPoint(x: x, y: center + amplitude - markerInset))
            limiterPath.addLine(to: CGPoint(x: x, y: center + amplitude - 2.5))
          }
          if sample.clipsWithoutLimiter {
            clippingPath.move(to: CGPoint(x: x, y: center - amplitude))
            clippingPath.addLine(to: CGPoint(x: x, y: center - amplitude + 1))
            clippingPath.move(to: CGPoint(x: x, y: center + amplitude))
            clippingPath.addLine(to: CGPoint(x: x, y: center + amplitude - 1))
          }
        }
        context.fill(
          envelopePath,
          with: .color(EditorTheme.audioWave.opacity(0.82))
        )
        var silencePath = Path()
        silencePath.move(to: CGPoint(x: 0, y: center))
        silencePath.addLine(to: CGPoint(x: canvas.width, y: center))
        context.stroke(
          silencePath,
          with: .color(EditorTheme.audioWave.opacity(0.7)),
          lineWidth: 0.75
        )
        let lineWidth = max(1, min(2, step * 0.65))
        context.stroke(limiterPath, with: .color(EditorTheme.audioWarning), lineWidth: lineWidth)
        context.stroke(clippingPath, with: .color(EditorTheme.audioClipping), lineWidth: lineWidth)

        if project.audio.normalizeLoudness {
          let ceiling = CGFloat(pow(10, project.audio.peakCeilingDB / 20))
          let limitOffset = maximumAmplitude * ceiling
          var ceilingPath = Path()
          ceilingPath.move(to: CGPoint(x: 0, y: center - limitOffset))
          ceilingPath.addLine(to: CGPoint(x: canvas.width, y: center - limitOffset))
          ceilingPath.move(to: CGPoint(x: 0, y: center + limitOffset))
          ceilingPath.addLine(to: CGPoint(x: canvas.width, y: center + limitOffset))
          context.stroke(
            ceilingPath,
            with: .color(EditorTheme.audioWarning.opacity(0.38)),
            style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
          )
        }
      }
      .mask {
        audioWaveformMask(width: trackWidth, clipLayout: clipLayout)
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
        RoundedRectangle(cornerRadius: 5)
          .fill(
            project.isClipSelected(clip.id)
              ? EditorTheme.audioBackgroundSelected
              : EditorTheme.audioBackground
          )
          .overlay {
            if project.isClipSelected(clip.id) {
              RoundedRectangle(cornerRadius: 5)
                .stroke(EditorTheme.selection.opacity(0.72), lineWidth: 1)
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

  private func audioWaveformMask(
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
        RoundedRectangle(cornerRadius: 5)
          .fill(.white)
          .frame(
            width: max(1, segmentWidth - clipGap + adjustment.width),
            height: 34
          )
          .offset(x: x + clipGap / 2 + adjustment.offset)
      }
    }
    .frame(width: trackWidth, height: 38, alignment: .leading)
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
          baseOffset: x + clipGap / 2,
          baseWidth: max(1, segmentWidth - clipGap),
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
        let pixelsPerSecond = trackWidth / max(project.duration, 0.01)
        let width =
          project.duration > 0
          ? trackWidth * item.duration / project.duration
          : 0
        let x =
          project.duration > 0
          ? trackWidth * item.startTime / project.duration
          : 0
        let adjustment = overlayAdjustment(
          for: item,
          pixelsPerSecond: pixelsPerSecond
        )
        let adjustedWidth = max(2, width + adjustment.width)
        RoundedRectangle(cornerRadius: 5)
          .fill(
            item.kind == .caption
              ? .blue : (item.kind == .text ? .purple : .orange)
          )
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
                    pixelsPerSecond: pixelsPerSecond
                  )
                  Spacer(minLength: 0)
                  overlayTrimHandle(
                    item: item,
                    edge: .trailing,
                    pixelsPerSecond: pixelsPerSecond
                  )
                }
              }
            }
          }
          .frame(width: adjustedWidth, height: 28)
          .contentShape(Rectangle().inset(by: -3))
          .gesture(
            DragGesture(
              minimumDistance: 0,
              coordinateSpace: .global
            )
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
          )
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
    }
    .frame(height: 34)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(trackTitle(for: kind))
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
    pixelsPerSecond: CGFloat
  ) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(.white)
      .frame(width: 7)
      .padding(.vertical, 3)
      .contentShape(Rectangle().inset(by: -4))
      .highPriorityGesture(
        DragGesture(
          minimumDistance: 1,
          coordinateSpace: .global
        )
          .onChanged { value in
            activeOverlayID = item.id
            activeOverlayEdge = edge
            overlayDragOffset = value.translation.width
          }
          .onEnded { value in
            let delta = clampedOverlayTrim(
              item: item,
              edge: edge,
              requestedOffset: value.translation.width,
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
      .onContinuousHover { phase in
        switch phase {
        case .active:
          NSCursor.resizeLeftRight.set()
        case .ended:
          NSCursor.arrow.set()
        }
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
  }
}

private final class TimelinePointerTrackingNSView: NSView {
  var onMoved: ((CGFloat) -> Void)?
  var onExited: (() -> Void)?
  private var pointerTrackingArea: NSTrackingArea?

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
  }

  override func mouseEntered(with event: NSEvent) {
    reportPointerLocation(from: event)
  }

  override func mouseMoved(with event: NSEvent) {
    reportPointerLocation(from: event)
  }

  override func mouseExited(with event: NSEvent) {
    onExited?()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func reportPointerLocation(from event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    onMoved?(min(max(0, location.x), bounds.width))
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

private struct TimelineContentMinXPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
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
  let hoveredX: CGFloat?
  let snapDistance: CGFloat

  var body: some View {
    let playbackX = duration > 0
      ? contentWidth * playback.playhead / duration
      : 0
    let anchoredX = duration > 0
      ? contentWidth * playback.anchoredPlayhead / duration
      : 0
    let isSnapped = !playback.isPlaying
      && hoveredX.map { abs($0 - anchoredX) <= snapDistance } == true
    let skimmerX = hoveredX.map {
      isSnapped ? anchoredX : $0
    }
    let activeX = playback.isPlaying ? playbackX : skimmerX
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        if !playback.isPlaying {
          Rectangle()
            .fill(Color.gray.opacity(0.58))
            .frame(width: 1, height: proxy.size.height)
            .offset(x: min(max(0, anchoredX - 0.5), contentWidth - 1))
        }
        if let activeX {
          let activeColor = isSnapped
            ? Color.yellow
            : Color.white.opacity(0.96)
          Rectangle()
            .fill(activeColor)
            .frame(width: 1.5, height: proxy.size.height)
            .offset(x: min(max(0, activeX - 0.75), contentWidth - 1.5))
            .shadow(color: .black.opacity(0.7), radius: 1)
          Image(systemName: "arrowtriangle.down.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(activeColor)
            .shadow(color: .black.opacity(0.75), radius: 1)
            .offset(
              x: min(max(0, activeX - 4.5), contentWidth - 9),
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
          Color.accentColor.opacity(0.48)
          Image(systemName: "film")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.58))
        }
      } else {
        HStack(spacing: 1) {
          ForEach(Array(images.enumerated()), id: \.offset) { _, image in
            Image(decorative: image, scale: 1)
              .resizable()
              .scaledToFit()
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
