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
          .onTapGesture {
            project.selectedClipID = clip.id
          }
      }
    }
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
