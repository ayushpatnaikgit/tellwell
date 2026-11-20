import Foundation

/// Vocabulary boosting in the speech recogniser: while decoding, word-pieces that spell out a listed name or term (the
/// user's vocabulary and the screen words) get a bonus, so a close call ("sid hunt" vs "Siddhant") tips toward the
/// listed spelling. Matching is by characters, so any split of the term into word-pieces works.
///
/// Guards (tuned in freeflow-local on synthetic speech, where this took names right from 18 to 40 of 120):
/// - only pieces the model already finds plausible are boosted (log-probability >= `floor`, within the top `topK`);
/// - a boosted piece may beat "nothing said here" only if it was within `blankMargin` of it, so no speech is invented;
/// - boosting runs as a second pass, and only boosted words that spell a whole listed term replace the words the
///   ordinary pass heard at the same time. A half-boosted word ("Siddhart") never reaches the text.
///
/// A port of freeflow-local's orukeet-ane boosting. Pure logic: no model calls, nothing logged.
struct TermBoost {
    typealias Token = WindowStitch.Token

    static let maxTerms = 100

    let terms: [String]                // as the user or the screen spells them
    var beta: Float = 6.0              // log-probability bonus per matching piece (8 began inserting wrong names)
    var floor: Float = -6.0            // never boost pieces less likely than this
    var topK = 20
    var blankMargin: Float = 4.0
    let keys: [[Character]]            // "▁" + lowercased term, spaces as "▁"

    /// A term being spelled out: which term, and how many characters of it have been emitted so far.
    struct Partial: Hashable { let term: Int; let pos: Int }

    init(terms: [String]) {
        self.terms = terms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        keys = self.terms.map { Array("▁" + $0.lowercased().replacingOccurrences(of: " ", with: "▁")) }
    }

    var isOn: Bool { !keys.isEmpty && beta > 0 }

    /// The terms in the vocabulary setting (separated by new lines, commas or semicolons, as cleanup reads it).
    static func vocabulary(_ setting: String) -> [String] {
        setting.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The list to boost: vocabulary first, then screen words; one spelling per term, at least 3 letters or digits.
    static func terms(vocabulary: [String], screen: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for term in vocabulary + screen {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = t.lowercased()
            guard key.filter({ $0.isASCII && ($0.isLetter || $0.isNumber) }).count >= 3, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(t)
        }
        return Array(out.prefix(maxTerms))
    }

    /// Word-pieces as the matcher sees them: lowercased, word starts as "▁".
    static func pieces(_ vocab: [String]) -> [[Character]] {
        vocab.map { Array($0.lowercased().replacingOccurrences(of: " ", with: "▁")) }
    }

    /// Partials after emitting `piece`, or nil if the piece spells no listed term from the current state.
    func advance(_ active: Set<Partial>, _ piece: [Character]) -> Set<Partial>? {
        guard !piece.isEmpty else { return nil }
        var next = Set<Partial>()
        var starts = Array(active)
        if piece[0] == "▁" { starts += keys.indices.map { Partial(term: $0, pos: 0) } }
        for p in starts {
            let key = keys[p.term]
            if p.pos + piece.count <= key.count && Array(key[p.pos..<(p.pos + piece.count)]) == piece {
                next.insert(Partial(term: p.term, pos: p.pos + piece.count))
            }
        }
        return next.isEmpty ? nil : next
    }

    /// Greedy choice with boosting from the raw token scores (word-pieces then blank, as the joint model computes
    /// them). `stock` is the model's own pick. Returns the chosen token, blank included.
    func choose(_ scores: [Float], stock: Int, blank: Int, pieces: [[Character]], active: inout Set<Partial>) -> Int {
        let top = scores.max() ?? 0
        let logZ = top + log(scores.reduce(Float(0)) { $0 + exp($1 - top) })
        let blankLP = scores[blank] - logZ
        var best = stock, bestScore = scores[stock] - logZ
        var bestNext: Set<Partial>?
        if stock != blank, let next = advance(active, pieces[stock]) {   // the model's own pick spells a term too
            bestScore += beta; bestNext = next
        }
        let candidates = scores.indices.filter { $0 != blank }.sorted { scores[$0] > scores[$1] }.prefix(topK)
        for id in candidates {
            let lp = scores[id] - logZ
            guard lp >= floor, let next = advance(active, pieces[id]) else { continue }
            let boosted = lp + beta
            if boosted > bestScore && (stock != blank || lp >= blankLP - blankMargin) {
                best = id; bestScore = boosted; bestNext = next
            }
        }
        if best != blank {
            active = bestNext ?? advance(active, pieces[best]) ?? []
        }
        return best
    }

    // MARK: - Taking whole terms from the boosted pass

    private static func startsWord(_ t: Token, _ pieces: [[Character]]) -> Bool { pieces[t.id].first == "▁" }

    /// Words of a token list: (first token index, end index, start time).
    static func words(_ tokens: [Token], pieces: [[Character]]) -> [(Int, Int, Double)] {
        var out: [(Int, Int, Double)] = []
        for i in tokens.indices where i == 0 || startsWord(tokens[i], pieces) {
            var end = i + 1
            while end < tokens.count && !startsWord(tokens[end], pieces) { end += 1 }
            out.append((i, end, tokens[i].time))
        }
        return out
    }

    /// The stock tokens, with each boosted word that spells a whole listed term swapped in for the stock words spoken
    /// at the same time. Boosted words that aren't whole terms are ignored. Also returns how many words were swapped.
    func acceptTerms(stock: [Token], boosted: [Token], pieces: [[Character]]) -> ([Token], Int) {
        let whole = Set(keys.map { String($0.dropFirst()) })    // lowercased, spaces as "▁"
        let edges = CharacterSet(charactersIn: "▁")
        var out = stock
        var swapped = 0
        let bw = Self.words(boosted, pieces: pieces)
        for (k, w) in bw.enumerated().reversed() {
            let spelled = String(boosted[w.0..<w.1].flatMap { pieces[$0.id] }).trimmingCharacters(in: edges)
            guard whole.contains(spelled.trimmingCharacters(in: .punctuationCharacters)) else { continue }
            let start = w.2, end = k + 1 < bw.count ? bw[k + 1].2 : .infinity
            let sw = Self.words(out, pieces: pieces).filter { $0.2 >= start - 0.12 && $0.2 < end - 0.01 }
            guard let first = sw.first, let last = sw.last else { continue }   // never insert a term into silence
            let replaced = String(out[first.0..<last.1].flatMap { pieces[$0.id] }).trimmingCharacters(in: edges)
            if replaced == spelled { continue }
            out.replaceSubrange(first.0..<last.1, with: boosted[w.0..<w.1])
            swapped += 1
        }
        return (out, swapped)
    }

    /// Use the listed spelling for any whole word that matches a term ignoring case ("grafana" -> "Grafana").
    func spellTerms(_ text: String) -> String {
        var out = text
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let pattern = "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\w-])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return out
    }
}
