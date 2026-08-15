import Foundation

@MainActor
final class PlaybackState: ObservableObject {
  @Published var playhead: Double = 0
  @Published var isPlaying = false
}
