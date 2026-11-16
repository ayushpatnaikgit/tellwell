import Foundation

/// Joining overlapping speech windows: each word must appear once. Invented tokens and times.
enum WindowStitchTests {
    private static let vocab = ["▁our", "▁lives", "▁the", "▁book", "▁is", "▁new", "."]
    private static func t(_ id: Int, _ time: Double) -> WindowStitch.Token { WindowStitch.Token(id: id, time: time) }
    private static func text(_ tokens: [WindowStitch.Token]) -> String {
        tokens.map { vocab[$0.id] }.joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func run() {
        // Speech ends before the middle of the overlap: the later window repeats the last words with slightly
        // different times. They must not be typed twice (this used to give "our lives. lives.").
        let ended = WindowStitch.join([t(0, 10.0), t(1, 10.5), t(6, 10.8)], [t(0, 10.05), t(1, 10.55), t(6, 10.85)],
                                      midpoint: 10.6, vocab: vocab)
        TestSupport.expectEqual(text(ended), "our lives.")

        // A pause at the midpoint, then more speech: the new words are kept, the repeated one isn't.
        let paused = WindowStitch.join([t(0, 10.0)], [t(0, 10.02), t(5, 11.5)], midpoint: 10.6, vocab: vocab)
        TestSupport.expectEqual(text(paused), "our new")

        // Speech across the midpoint: cut at the first word after it and resume at the same word.
        let across = WindowStitch.join([t(2, 11.0), t(3, 12.0)], [t(2, 11.02), t(3, 12.05), t(4, 12.5)],
                                       midpoint: 11.5, vocab: vocab)
        TestSupport.expectEqual(text(across), "the book is")

        TestSupport.expectEqual(text(WindowStitch.join([], [t(0, 1)], midpoint: 0, vocab: vocab)), "our")
    }
}
