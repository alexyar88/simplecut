import Foundation

enum CaptionGenerator {
  static func makeDrafts(
    words: [CaptionWord],
    fallback: [CaptionDraft] = [],
    maximumCharacters: Int = 38,
    maximumDuration: Double = 3
  ) -> [CaptionDraft] {
    guard !words.isEmpty else { return fallback }
    var drafts: [CaptionDraft] = []
    var current: [CaptionWord] = []

    func flush() {
      guard let first = current.first, let last = current.last else { return }
      drafts.append(
        CaptionDraft(
          text: current.map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
          startTime: first.startTime,
          endTime: last.endTime
        )
      )
      current.removeAll(keepingCapacity: true)
    }

    for word in words {
      let proposed = (current.map(\.text) + [word.text])
        .joined(separator: " ")
      let start = current.first?.startTime ?? word.startTime
      if !current.isEmpty,
        proposed.count > maximumCharacters
          || word.endTime - start > maximumDuration
      {
        flush()
      }
      current.append(word)
      if current.count >= 2,
        word.text.trimmingCharacters(in: .whitespaces).last.map({
          ".!?…".contains($0)
        }) == true
      {
        flush()
      }
    }
    flush()
    return drafts.filter { !$0.text.isEmpty && $0.endTime > $0.startTime }
  }
}
