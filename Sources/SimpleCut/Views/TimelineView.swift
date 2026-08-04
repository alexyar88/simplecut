import SwiftUI

struct TimelineView: View {
  @EnvironmentObject private var project: EditorProject

  var body: some View {
    Group {
      if project.clips.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "timeline.selection")
            .font(.title2)
            .foregroundStyle(.tertiary)
          Text("Таймлайн появится после добавления видео")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        timelineContent
      }
    }
    .padding(12)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
  }

  private var timelineContent: some View {
    VStack(spacing: 8) {
      timeRuler
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.06))
          waveform(in: proxy.size)
          clipBoundaries(in: proxy.size)
          playhead(in: proxy.size)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              let ratio = min(
                1,
                max(0, value.location.x / max(proxy.size.width, 1))
              )
              project.seek(to: ratio * project.duration)
            }
        )
      }
      .frame(height: 112)

      overlayTrack
    }
  }

  private var timeRuler: some View {
    HStack {
      Text(project.playhead.timestamp)
        .monospacedDigit()
      Text("/")
        .foregroundStyle(.secondary)
      Text(project.duration.timestamp)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(project.clips.count) фрагм.")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
  }

  private func waveform(in size: CGSize) -> some View {
    Canvas { context, canvas in
      guard !project.waveform.isEmpty else { return }
      let center = canvas.height / 2
      let step = canvas.width / CGFloat(project.waveform.count)
      var path = Path()
      for (index, value) in project.waveform.enumerated() {
        let x = CGFloat(index) * step
        let amplitude = CGFloat(value) * center * 0.86
        path.move(to: CGPoint(x: x, y: center - amplitude))
        path.addLine(to: CGPoint(x: x, y: center + amplitude))
      }
      context.stroke(
        path,
        with: .color(.mint.opacity(0.9)),
        lineWidth: max(1, step * 0.65)
      )
    }
  }

  private func clipBoundaries(in size: CGSize) -> some View {
    return ZStack(alignment: .leading) {
      ForEach(Array(project.clips.enumerated()), id: \.element.id) {
        index,
        clip in
        let start = project.clips.prefix(index).reduce(0) {
          $0 + $1.duration
        }
        let width =
          project.duration > 0
          ? size.width * clip.duration / project.duration
          : 0
        let offset =
          project.duration > 0
          ? size.width * start / project.duration
          : 0
        RoundedRectangle(cornerRadius: 7)
          .stroke(
            project.selectedClipID == clip.id ? .blue : .white.opacity(0.18),
            lineWidth: project.selectedClipID == clip.id ? 3 : 1
          )
          .frame(width: max(1, width), height: size.height)
          .offset(x: offset)
          .overlay {
            if project.selectedClipID == clip.id {
              HStack {
                trimHandle(
                  clip: clip,
                  edge: .leading,
                  pixelsPerSecond: size.width / max(project.duration, 0.01)
                )
                Spacer()
                trimHandle(
                  clip: clip,
                  edge: .trailing,
                  pixelsPerSecond: size.width / max(project.duration, 0.01)
                )
              }
              .frame(width: max(12, width), height: size.height)
            }
          }
          .onTapGesture {
            project.selectedClipID = clip.id
          }
          .draggable(clip.id.uuidString)
          .dropDestination(for: String.self) { values, _ in
            guard let rawID = values.first, let sourceID = UUID(uuidString: rawID)
            else { return false }
            project.moveClip(id: sourceID, before: clip.id)
            return true
          }
          .contextMenu {
            Button("Разрезать посередине") {
              project.selectedClipID = clip.id
              project.seek(to: start + clip.duration / 2)
              project.splitAtPlayhead()
            }
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
              project.selectedClipID = clip.id
              project.deleteSelectedClip()
            }
          }
      }
    }
  }

  private func trimHandle(
    clip: VideoClip,
    edge: TrimEdge,
    pixelsPerSecond: Double
  ) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(.blue)
      .frame(width: 8)
      .contentShape(Rectangle().inset(by: -4))
      .highPriorityGesture(
        DragGesture()
          .onEnded { value in
            let points =
              edge == .leading
              ? value.translation.width
              : -value.translation.width
            project.trimClip(
              id: clip.id,
              edge: edge,
              by: max(0, points / max(pixelsPerSecond, 0.01))
            )
          }
      )
      .help(
        edge == .leading
        ? "Потяните вправо, чтобы обрезать начало"
        : "Потяните влево, чтобы обрезать конец"
      )
  }

  private func playhead(in size: CGSize) -> some View {
    let x =
      project.duration > 0
      ? size.width * project.playhead / project.duration
      : 0
    return Rectangle()
      .fill(.yellow)
      .frame(width: 2, height: size.height + 10)
      .offset(x: x)
      .shadow(color: .black.opacity(0.5), radius: 2)
  }

  private var overlayTrack: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.purple.opacity(0.08))
        ForEach(project.overlays) { item in
          let width =
            project.duration > 0
            ? proxy.size.width * item.duration / project.duration
            : 0
          let x =
            project.duration > 0
            ? proxy.size.width * item.startTime / project.duration
            : 0
          RoundedRectangle(cornerRadius: 5)
            .fill(
              item.kind == .caption
                ? .blue : (item.kind == .text ? .purple : .orange)
            )
            .overlay(alignment: .leading) {
              Text(layerTitle(item))
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
            }
            .frame(width: max(24, width), height: 28)
            .offset(x: x)
            .onTapGesture {
              project.selectedOverlayID = item.id
            }
        }
      }
    }
    .frame(height: 34)
  }

  private func layerTitle(_ item: OverlayItem) -> String {
    switch item.kind {
    case .text: item.text ?? "Текст"
    case .caption: item.text ?? "Субтитры"
    case .image: "Изображение"
    }
  }
}
