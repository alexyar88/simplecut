import Foundation

@MainActor
final class PlaybackState: ObservableObject {
  @Published var playhead: Double = 0
  @Published var anchoredPlayhead: Double = 0
  @Published var timelineSkimmerTime: Double?
  @Published var isPlaying = false
}
