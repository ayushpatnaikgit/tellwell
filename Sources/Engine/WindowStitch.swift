import Foundation

/// Joins the transcripts of overlapping speech windows so that each spoken word appears exactly once.
///
/// Both windows are cut at the first word starting at or after the middle of their overlap. Timestamps for the same
/// word differ slightly between windows, so the later window resumes at the same word near the cut, else at the
/// nearest word start, else at the first word after it. If the earlier window has no word after the midpoint (speech
/// ended or paused there), all of it is kept and the later window contributes only words that start clearly after its
/// last one; otherwise its last word would be typed twice.
enum WindowStitch {
    struct Token: Equatable {
        let id: Int
        /// Seconds from the start of the audio.
        let time: Double
        /// How sure the recogniser was of this word-piece (0-1); 1 when unknown.
        var prob: Float = 1
        /// On a word's first piece from the ordinary pass: what the encoder heard over that word (see `WordFeatures`).
        var features: WordFeatures? = nil
    }

    /// Per-word speech features for the suspect-word labeller (TwoPass): the mean of the encoder's last layer over
    /// the word's frames, the word's length in frames and the silent frames after it.
    struct WordFeatures: Equatable {
        let mean: [Float]
        let frames: Int
        let pause: Int
    }

    /// Parakeet's "<unk>" word-piece.
    static let unknownID = 0

    /// Whether `tokens` contain three or more "<unk>" pieces in a row (a failed decode, not a rare word).
    static func hasUnknownRun(_ tokens: [Token]) -> Bool {
        var run = 0
        for t in tokens {
            run = t.id == unknownID ? run + 1 : 0
            if run >= 3 { return true }
        }
        return false
    }

    /// The words of `tokens` (pieces joined, split where a piece starts with "▁"), each with the features of its
    /// first piece. Matches the transcript's words split on spaces.
    static func words(_ tokens: [Token], vocab: [String]) -> [(word: String, features: WordFeatures?)] {
        var out: [(word: String, features: WordFeatures?)] = []
        for t in tokens {
            let piece = vocab[t.id]
            let starts = piece.hasPrefix("▁") || piece.hasPrefix(" ")
            let text = String(piece.drop(while: { $0 == "▁" || $0 == " " }))
            if starts || out.isEmpty {
                if text.isEmpty && starts { out.append(("", t.features)); continue }
                out.append((text, t.features))
            } else {
                out[out.count - 1].word += text
            }
        }
        return out.filter { !$0.word.isEmpty }
    }

    /// How far apart the same word's start may be between two windows.
    static let tolerance = 0.4

    /// `all` followed by the part of `next` that isn't already in it. `midpoint` is the middle of the overlap.
    static func join(_ all: [Token], _ next: [Token], midpoint: Double, vocab: [String]) -> [Token] {
        func startsWord(_ t: Token) -> Bool { vocab[t.id].hasPrefix(" ") || vocab[t.id].hasPrefix("▁") }
        func word(_ tokens: [Token], at i: Int) -> String {
            var end = i + 1
            while end < tokens.count && !startsWord(tokens[end]) { end += 1 }
            return tokens[i..<end].map { vocab[$0.id] }.joined().lowercased().filter { $0.isLetter || $0.isNumber }
        }

        guard let cut = all.firstIndex(where: { startsWord($0) && $0.time >= midpoint }) else {
            guard let last = all.last else { return next }
            let from = next.indices.first { startsWord(next[$0]) && next[$0].time > last.time + tolerance } ?? next.count
            return all + next[from...]
        }
        let cutTime = all[cut].time
        let cutWord = word(all, at: cut)
        let near = next.indices.filter { startsWord(next[$0]) && abs(next[$0].time - cutTime) <= tolerance }
            .sorted { abs(next[$0].time - cutTime) < abs(next[$1].time - cutTime) }
        let from = near.first { word(next, at: $0) == cutWord } ?? near.first
            ?? next.indices.first { startsWord(next[$0]) && next[$0].time >= cutTime } ?? next.count
        return Array(all[..<cut]) + next[from...]
    }
}
