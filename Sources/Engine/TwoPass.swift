import Foundation

/// English two-pass cleanup: a suspect-word labeller on the recogniser's own features, a router that skips cleanup
/// when nothing in the transcript calls for it, and a gate that limits what the cleanup model may change.
///
/// - Labeller: logistic regression on each heard word's speech features (mean of the encoder's last layer over the
///   word, its length and the pause after it). Flags the words most likely misheard.
/// - Router: when the transcript has no fillers, repeats, correction cues, spoken punctuation or code, number words,
///   near-matches of listed terms, greetings or flagged words, and already has punctuation, the transcript is used as
///   heard and the cleanup model doesn't run.
/// - Gate: the cleanup model may delete words (removing fillers, restarts and corrections is its job), except an
///   unexplained run of 3 or more words; it may swap or add a word only on a flagged word, a number, a listed term, or
///   by joining heard words ("free flow" -> "FreeFlow"). Anything else is put back as heard.
///
/// Ported from the Python lab code (tellwell-lab/fused/en_dict_gate.py, en_router.py); Tests/TwoPassTests.swift checks
/// it against that code's outputs on synthetic text.
enum TwoPass {
    // MARK: - Words

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                               "nineteen", "twenty"]
    private static let onesPattern = try! NSRegularExpression(pattern: "\\b(" + ones.joined(separator: "|") + ")\\b")
    private static let tokenPattern = try! NSRegularExpression(pattern: "[a-z0-9']+")

    /// Lower-case word tokens with number words up to twenty as digits ("Twenty-one" -> ["20", "1"]).
    static func normalise(_ s: String) -> [String] {
        var t = s.lowercased().replacingOccurrences(of: "-", with: " ")
        let ns = t as NSString
        var out = ""
        var last = 0
        for m in onesPattern.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += String(ones.firstIndex(of: ns.substring(with: m.range))!)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        t = out
        let n2 = t as NSString
        return tokenPattern.matches(in: t, range: NSRange(location: 0, length: n2.length)).map { n2.substring(with: $0.range) }
    }

    enum Op: Equatable { case ok, sub, del, ins }

    /// Word-level edit alignment of `a` to `b` (Levenshtein, the same tie-breaking as the lab code).
    static func align(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1] ? 1 : 0))
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (a[i - 1] != b[j - 1] ? 1 : 0) {
                ops.append(a[i - 1] == b[j - 1] ? .ok : .sub); i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                ops.append(.del); i -= 1
            } else {
                ops.append(.ins); j -= 1
            }
        }
        return ops.reversed()
    }

    // MARK: - Gate

    static let fillers: Set<String> = ["uh", "um", "uhh", "umm", "hmm", "mm", "er", "erm", "ah", "eh", "hm", "mhm"]
    private static let soft: Set<String> = ["like", "you", "know", "so", "well", "sort", "of", "kind", "basically", "i",
                                            "mean", "just", "really", "okay", "ok", "yeah", "right", "and", "then"]
    private static let numberWord = try! NSRegularExpression(pattern:
        "^(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|" +
        "seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|" +
        "billion|\\w+ties|first|second|third|\\w+th|percent|and|point|o|oh)$")
    private static let cues = try! NSRegularExpression(pattern:
        "\\b(actually|sorry|i mean|scratch that|no wait|wait|rather|correction|make that|no no)\\b")
    /// A deleted run with this many real words needs a reason (a correction cue, a restart, numbers) or it is put back.
    static let maxFreeDelete = 3
    /// How far from a word (in heard words) a correction phrase counts.
    static let cueReach = 6
    /// At least this many blocked edits, and more than this share of the output, means the cleanup is unreliable.
    static let unreliableMinimum = 5, unreliableShare = 0.25
    /// Spoken number words: a deleted run containing one is the cleanup writing a number, not dropping content.
    private static let spokenNumbers: Set<String> = Set("""
        zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen
        eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion first
        second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth
        sixteenth seventeenth eighteenth nineteenth twentieth thirtieth hundredth thousandth double triple point percent
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// The cleanup output with the changes the gate doesn't allow undone. `flags` has one entry per heard word
    /// (`heard` split on spaces); `terms` are listed vocabulary and screen words.
    static func gate(heard: String, cleaned: String, flags: [Bool], terms: [String] = []) -> String {
        let H = heard.split(separator: " ").map(String.init)
        var O: [String] = [], SEP: [String] = []            // output words and the whitespace after each
        for ch in cleaned.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isWhitespace {
                if SEP.count < O.count { SEP.append("") }
                SEP[SEP.count - 1].append(ch)
            } else {
                if SEP.count < O.count { O[O.count - 1].append(ch) } else { O.append(String(ch)) }
            }
        }
        while SEP.count < O.count { SEP.append("") }
        guard flags.count == H.count else { return cleaned }
        var voc = Set(terms.flatMap { normalise($0) })
        for t in terms { voc.insert(t.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) }
        let ht = H.enumerated().flatMap { i, w in normalise(w).map { ($0, i) } }
        let ot = O.enumerated().flatMap { j, w in normalise(w).map { ($0, j) } }
        let hn = ht.map(\.0)
        let ops = align(hn, ot.map(\.0))

        func joins(_ t: String, _ k: Int) -> Bool {
            for s0 in [k - 1, k, k + 1] {
                var acc = ""
                var m = max(0, s0)
                while m < min(hn.count, s0 + 4) {
                    acc += hn[m]
                    if acc == t && m > s0 { return true }
                    m += 1
                }
            }
            return false
        }
        func free(_ t: String, _ k: Int) -> Bool { voc.contains(t) || t.contains(where: \.isNumber) || joins(t, k) }
        // Words said after the first correction phrase ("... Actually, the van is booked for Saturday"): the
        // cleanup may move them to where the corrected words were.
        let joinedHeard = hn.joined(separator: " ")
        let nsHeard = joinedHeard as NSString
        let late: Set<String> = cues.firstMatch(in: joinedHeard, range: NSRange(location: 0, length: nsHeard.length)).map {
            let before = nsHeard.substring(to: $0.range.location + $0.range.length).split(separator: " ").count
            return Set(hn[min(hn.count, before)...])
        } ?? []
        func cueNear(_ i: Int) -> Bool {
            let lo = max(0, i - cueReach), hi = min(H.count, i + cueReach + 1)
            return matches(cues, normalise(H[lo..<hi].joined(separator: " ")).joined(separator: " "))
        }

        var badSub: [Int: [String]] = [:]
        var badIns = Set<Int>()
        var delRuns: [(tokens: [Int], at: Int)] = []
        var run: [Int] = []
        var hi = 0, oi = 0
        for op in ops {
            if op != .del && !run.isEmpty { delRuns.append((run, oi)); run = [] }
            switch op {
            case .ok:
                hi += 1; oi += 1
            case .sub:
                let i = ht[hi].1, j = ot[oi].1
                if !(flags[i] || matches(numberWord, hn[hi]) || free(ot[oi].0, hi) || cueNear(i) || late.contains(ot[oi].0)) {
                    badSub[j, default: []].append(H[i])
                }
                hi += 1; oi += 1
            case .del:
                run.append(hi); hi += 1
            case .ins:
                let j = ot[oi].1
                let near = (hi > 0 && flags[ht[hi - 1].1]) || (hi < ht.count && flags[ht[hi].1])
                if !(near || free(ot[oi].0, hi)) { badIns.insert(j) }
                oi += 1
            }
        }
        if !run.isEmpty { delRuns.append((run, oi)) }
        // So many blocked edits that the cleanup went off the rails (repeated a paragraph, invented a sentence): use
        // what was heard.
        let blocked = badIns.count + badSub.count
        if blocked >= unreliableMinimum && Double(blocked) > unreliableShare * Double(O.count) {
            return heard.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var restoreBefore: [Int: [String]] = [:]
        for (idx, at) in delRuns {
            let raw = Array(Set(idx.map { ht[$0].1 })).sorted()
            if raw.count < maxFreeDelete || raw.allSatisfy({ flags[$0] }) { continue }
            let gone = idx.map { hn[$0] }
            let content = gone.filter { !fillers.contains($0) && !soft.contains($0) && $0.count > 2 }
            let from = min(hn.count, idx[idx.count - 1] + 1)
            let around = Set(hn[max(0, idx[0] - gone.count - 4)..<idx[0]]).union(hn[from..<min(hn.count, from + gone.count + 4)])
            let restart = content.filter(around.contains).count * 2 >= content.count   // half its words come again
            let hasCue = matches(cues, gone.joined(separator: " "))                    // the run is a correction
            let numbers = gone.contains { $0.contains(where: \.isNumber) || spokenNumbers.contains($0) }
            let bareNo = gone.dropFirst().contains("no")                               // "30 seconds no wait 60"
            if content.count < maxFreeDelete || restart || numbers || bareNo || hasCue || cueNear(raw[0]) || cueNear(raw[raw.count - 1]) {
                continue
            }
            let j = at < ot.count ? ot[at].1 : O.count
            restoreBefore[j, default: []] += raw.map { H[$0] }
        }
        // Kept words and the whitespace after each, so the cleanup's line breaks survive.
        var words: [String] = [], seps: [String] = []
        func put(_ w: String, _ sep: String = " ") {
            if let last = seps.last, last.isEmpty { seps[seps.count - 1] = " " }
            words.append(w); seps.append(sep)
        }
        func trailingPunctuation(_ w: String) -> String { String(w.reversed().prefix { ".,!?;:".contains($0) }.reversed()) }
        for (j, w) in O.enumerated() {
            for h in restoreBefore[j] ?? [] { put(h) }
            if let back = badSub[j] {
                for h in back where words.last != h { put(h) }
                let tail = trailingPunctuation(w)
                if !tail.isEmpty, let last = words.last, trailingPunctuation(last).isEmpty { words[words.count - 1] += tail }
                if !seps.isEmpty { seps[seps.count - 1] = SEP[j] }
            } else if !badIns.contains(j) {
                put(w, SEP[j])
            } else if SEP[j].contains("\n"), !seps.isEmpty {
                seps[seps.count - 1] = SEP[j]
            }
        }
        for h in restoreBefore[O.count] ?? [] { put(h) }
        return zip(words, seps).map { $0 + $1 }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Router

    private static let cueAnyCase = try! NSRegularExpression(pattern:
        "\\b(actually|sorry|i mean|scratch that|no wait|wait|rather|correction|make that|no no)\\b", options: .caseInsensitive)
    private static let softFillers = try! NSRegularExpression(pattern:
        "\\b(basically|you know|kind of|sort of|literally|i guess|so yeah|i mean)\\b|\\blike,", options: .caseInsensitive)
    private static let spoken = try! NSRegularExpression(pattern:
        "\\b(comma|period|full stop|question mark|exclamation (mark|point)|new line|new paragraph|colon|semicolon|dot|" +
        "slash|underscore|dash|hyphen|at sign|hashtag|hash|open (bracket|paren)|close (bracket|paren)|quote|unquote|" +
        "bullet|asterisk|backtick)\\b", options: .caseInsensitive)
    private static let numberWords = try! NSRegularExpression(pattern:
        "\\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|" +
        "seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|" +
        "percent)\\b", options: .caseInsensitive)
    private static let greeting = try! NSRegularExpression(pattern:
        "^(hi|hello|hey|dear)\\b|\\b(regards|cheers|thanks|thank you|best wishes|sincerely)\\W*$", options: .caseInsensitive)
    private static let punctuation = try! NSRegularExpression(pattern: "[.,?!]")
    private static let letters = try! NSRegularExpression(pattern: "[a-z0-9']+")

    /// Whether the transcript can be used as heard, without running the cleanup model.
    static func canSkipCleanup(heard: String, flags: [Bool], terms: [String] = []) -> Bool {
        let text = heard.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, flags.allSatisfy({ !$0 }) else { return false }
        let toks = normalise(text)
        if toks.contains(where: fillers.contains) { return false }
        for k in 1...3 where toks.count >= 2 * k {
            for i in 0...(toks.count - 2 * k) where Array(toks[i..<(i + k)]) == Array(toks[(i + k)..<(i + 2 * k)]) {
                return false
            }
        }
        for r in [cueAnyCase, softFillers, spoken, numberWords, greeting] where matches(r, text) { return false }
        if !matches(punctuation, text) { return false }
        if nearTerm(text, terms) { return false }
        return true
    }

    /// Whether some run of heard words, joined, looks like a listed term that isn't already spelled out.
    static func nearTerm(_ heard: String, _ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let low = heard.lowercased()
        let ns = low as NSString
        let words = letters.matches(in: low, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        let squashed = low.replacingOccurrences(of: " ", with: "")
        for term in terms {
            let t = term.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard !t.isEmpty, !squashed.contains(t) else { continue }
            let span = term.split(separator: " ").count + 2
            for k in 1..<span {
                for i in words.indices {
                    let joined = words[i..<min(words.count, i + k)].joined()
                    if SequenceMatcher(t, joined).ratio() > 0.7 { return true }
                }
            }
        }
        return false
    }

    // MARK: - Labeller

    /// Logistic regression over [log(1 + frames), log(1 + pause), mean encoder vector], standardised.
    struct Labeller: Decodable {
        let mean: [Float]
        let scale: [Float]
        let weights: [Float]
        let bias: Float
        /// Probability above which a word is flagged (set so about 5% of training words are).
        let threshold: Float

        var isValid: Bool { !weights.isEmpty && mean.count == weights.count && scale.count == weights.count }

        func probability(_ f: WindowStitch.WordFeatures) -> Float {
            guard isValid, f.mean.count + 2 == weights.count else { return 0 }
            var z = bias
            let head = [log1p(Float(f.frames)), log1p(Float(f.pause))]
            for (k, x) in head.enumerated() { z += weights[k] * (x - mean[k]) / scale[k] }
            for (d, x) in f.mean.enumerated() {
                let k = d + 2
                z += weights[k] * ((x.isFinite ? x : 0) - mean[k]) / scale[k]
            }
            return 1 / (1 + exp(-z))
        }

        /// One flag per heard word; words without features are not flagged.
        func flags(_ words: [(word: String, features: WindowStitch.WordFeatures?)]) -> [Bool] {
            words.map { w in w.features.map { probability($0) >= threshold } ?? false }
        }
    }

    /// Carries flags from the words the recogniser heard onto `text` (the transcript after filler stripping and name
    /// correction), matching words by their normalised form. Words that don't match are not flagged.
    static func flags(for text: String, heard: [String], heardFlags: [Bool]) -> [Bool] {
        let target = text.split(separator: " ").map(String.init)
        guard heard.count == heardFlags.count else { return [Bool](repeating: false, count: target.count) }
        let a = heard.map { normalise($0).joined(separator: " ") }
        let b = target.map { normalise($0).joined(separator: " ") }
        var out = [Bool](repeating: false, count: target.count)
        for op in SequenceMatcher(a, b, autojunk: false).opcodes() where op.tag == .equal {
            for k in 0..<(op.i2 - op.i1) { out[op.j1 + k] = heardFlags[op.i1 + k] }
        }
        return out
    }
}
