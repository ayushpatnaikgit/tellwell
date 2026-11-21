import Foundation

/// Picks the unusual words on screen (LoRA, MLX, Qwen3, Siddhant) from OCR text, and the ones that sound like part of
/// what was said, so cleanup can spell a misheard name or term the way it appears on screen.
///
/// A port of freeflow-local's screen_words.py; the rules and thresholds were tuned there on invented cases.
/// Nothing here is logged or stored.
enum ScreenWords {
    static let maxWords = 40
    /// OCR reads the screen several times; a word read the same way at least twice is real.
    static let minReads = 2
    /// Only screen words that sound like a 1-3 word stretch of the transcript are sent to cleanup.
    static let matchThreshold = 0.75
    static let maxSent = 12

    private static let token = try! NSRegularExpression(
        pattern: #"(?:\d+-)?[A-Za-z0-9_.]*[A-Za-z][A-Za-z0-9]*(?:[\-+'][A-Za-z0-9]+)*\+*[A-Za-z0-9_.]*"#)
    private static let skip: Set<String> = ["ok", "id", "ui", "url", "urls", "http", "https", "www", "com", "md", "py",
                                            "sh", "js", "ts", "json", "html", "png", "jpg", "pdf", "txt", "app",
                                            "ctrl", "cmd", "esc", "tab", "pm", "am"]
    private static let gluedExtension = try! NSRegularExpression(
        pattern: #"^([A-Za-z]{3,}?)(?:md|sh|py|js|ts|txt|json|html|swift|yml|yaml|toml)$"#)
    private static let suffixes = ["ings", "ing", "ers", "er", "ed", "es", "s", "ly"]

    /// The system word list (/usr/share/dict/words), lowercased. Loaded once; tests can replace it.
    nonisolated(unsafe) static var dictionary: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }()

    // MARK: - Word strength

    static func inDictionary(_ word: String) -> Bool {
        let w = word.lowercased()
        let known = dictionary
        if known.contains(w) { return true }
        for suffix in suffixes where w.hasSuffix(suffix) {
            let stem = String(w.dropLast(suffix.count))
            guard stem.count >= 3 else { continue }
            if known.contains(stem) || known.contains(stem + "e") { return true }
            let chars = Array(stem)
            if chars.count > 3 && chars[chars.count - 1] == chars[chars.count - 2] && known.contains(String(chars.dropLast())) {
                return true
            }
        }
        return false
    }

    /// 2 = clearly a name or term (LoRA, MLX, Qwen3, Siddhant), 1 = unknown lowercase word (pgvector), 0 = skip.
    static func strength(_ word: String) -> Int {
        let letters = word.filter { $0.isASCII && $0.isLetter }
        if letters.count < 2 || skip.contains(word.lowercased()) || word.contains("_") || word.contains(".") { return 0 }
        if let m = gluedExtension.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)),
           let r = Range(m.range(at: 1), in: word) {
            let stem = String(word[r])
            if isUpper(stem) || inDictionary(stem) { return 0 }
        }
        if word.range(of: "[a-z][A-Z]", options: .regularExpression) != nil { return 2 }   // LoRA, FreeFlow, iPhone
        if word.range(of: "[0-9]", options: .regularExpression) != nil { return 2 }        // Qwen3, gpt-4o, M4
        if isUpper(word) { return word.count <= 8 ? 2 : 0 }                                 // MLX (not single letters)
        if letters.count < 4 || inDictionary(word) { return 0 }
        if word.first?.isUppercase == true { return 2 }                                     // Siddhant, Zulip
        return letters.count >= 5 ? 1 : 0                                                   // kubectl, pgvector
    }

    /// Python's str.isupper(): at least one cased letter, and every cased letter uppercase.
    static func isUpper(_ s: String) -> Bool {
        let cased = s.filter { $0.isUppercase || $0.isLowercase }
        return !cased.isEmpty && cased.allSatisfy(\.isUppercase)
    }

    /// Unusual words read at least `minReads` times, strongest and most frequent first, one spelling each.
    static func screenWords(_ lines: [String], limit: Int = maxWords, minReads: Int = minReads) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []                       // first-seen order, for spelling ties
        var level: [String: Int] = [:]
        var spellings: [String: [(String, Int)]] = [:]
        for line in lines {
            let ns = line as NSString
            for m in token.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                var word = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".-'"))
                if word.hasSuffix("'s") { word = String(word.dropLast(2)) }
                let s = word.isEmpty ? 0 : strength(word)
                guard s > 0 else { continue }
                let key = word.lowercased()
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
                level[key] = max(level[key] ?? 0, s)
                var list = spellings[key] ?? []
                if let i = list.firstIndex(where: { $0.0 == word }) { list[i].1 += 1 } else { list.append((word, 1)) }
                spellings[key] = list
            }
        }
        let ranked = order.filter { counts[$0]! >= minReads }.sorted {
            (-(level[$0]!), -(counts[$0]!), $0) < (-(level[$1]!), -(counts[$1]!), $1)
        }
        return ranked.prefix(limit).map { key in
            // Counter.most_common(1): the highest count, earliest seen on ties.
            spellings[key]!.reduce(spellings[key]![0]) { $1.1 > $0.1 ? $1 : $0 }.0
        }
    }

    // MARK: - Matching what was said

    private static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10",
        // ordinals: "8-bit" is often heard as "eighth bit"
        "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5", "sixth": "6", "seventh": "7",
        "eighth": "8", "ninth": "9", "tenth": "10"]
    private static let sounds: [(String, String)] = [
        ("wh", "h"), ("ph", "f"), ("ck", "k"), ("qu", "k"), ("q", "k"), ("c", "k"), ("x", "ks"), ("z", "s"),
        ("w", "v"), ("dh", "d"), ("th", "t"), ("gh", "g")]

    static func letters(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }

    /// Rough sound-alike key: similar consonants merged, vowels after the first letter dropped (LoRA = Laura).
    /// `mergeVoicing` also treats d/t, b/p, g/k and v/f as one sound ("Podnamic" ~ Patnaik), for correcting names.
    static func sound(_ text: String, mergeVoicing: Bool = false) -> String {
        guard !mergeVoicing else {
            let voiceless: [Character: Character] = ["d": "t", "b": "p", "g": "k", "v": "f"]
            var out = ""
            for c in sound(text).map({ voiceless[$0] ?? $0 }) where out.last != c { out.append(c) }
            return out
        }
        var s = letters(text)
        for (a, b) in sounds { s = s.replacingOccurrences(of: a, with: b) }
        guard let head = s.first else { return s }
        // any opening vowel counts as the same sound: recognisers often swap it ("AuroKit" for Orukeet)
        let first: Character = "aeiou".contains(head) ? "a" : head
        let rest = String(s.dropFirst()).filter { !"aeiouy".contains($0) }
        var out = ""
        for c in String(first) + rest where out.last != c { out.append(c) }
        return out
    }

    /// Mean of sound-alike and spelling similarity; either alone matched too much.
    static func similarity(_ word: String, _ spoken: String, mergeVoicing: Bool = false) -> Double {
        let byLetters = SequenceMatcher(letters(word), letters(spoken)).ratio()
        let a = sound(word, mergeVoicing: mergeVoicing), b = sound(spoken, mergeVoicing: mergeVoicing)
        let bySound = a.count >= 2 ? SequenceMatcher(a, b).ratio() : 0.0
        return (byLetters + bySound) / 2
    }

    /// A string's letters and sound key, worked out once for comparing against many others.
    struct Prepared {
        let letters: String, sound: String
        init(_ text: String) { letters = ScreenWords.letters(text); sound = ScreenWords.sound(text) }
        /// The same value as `similarity(self, other)` whenever that is 0.3 or more (0 below).
        func similarity(_ other: Prepared) -> Double {
            // Neither ratio can exceed 2 * shorter / total length; skip the matching when even that is far off.
            func bound(_ a: String, _ b: String) -> Double {
                let total = a.count + b.count
                return total == 0 ? 0 : 2 * Double(min(a.count, b.count)) / Double(total)
            }
            let soundBound = sound.count >= 2 ? bound(sound, other.sound) : 0
            if (bound(letters, other.letters) + soundBound) / 2 < 0.3 { return 0 }
            let byLetters = SequenceMatcher(letters, other.letters).ratio()
            let bySound = sound.count >= 2 ? SequenceMatcher(sound, other.sound).ratio() : 0.0
            return (byLetters + bySound) / 2
        }
    }

    private static let spokenToken = try! NSRegularExpression(pattern: "[A-Za-z0-9']+")

    static func digits(_ s: String) -> [String] {
        let ns = s as NSString
        return (try! NSRegularExpression(pattern: "[0-9]+")).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// The words that sound like a 1-3 word stretch of the transcript ("Laura" -> LoRA, "or a keet" -> Orukeet).
    static func relevant(_ words: [String], transcript: String,
                         threshold: Double = matchThreshold, limit: Int = maxSent) -> [String] {
        let ns = transcript as NSString
        let tokens = spokenToken.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).map { m -> String in
            let t = ns.substring(with: m.range)
            return numbers[t.lowercased()] ?? t
        }
        var spans: [String] = []
        for n in 1...3 where tokens.count >= n {
            for i in 0...(tokens.count - n) { spans.append(tokens[i..<(i + n)].joined(separator: " ")) }
        }
        let spoken = Set(tokens.map(letters))
        let spokenDigits = Set(tokens.flatMap(digits))
        var scored: [(Double, String)] = []
        for word in words {
            let w = letters(word)
            if spoken.contains(w) { continue }                       // already spelled this way: nothing to fix
            if digits(word).contains(where: { !spokenDigits.contains($0) }) { continue }  // numbers must be said
            // Python: max((similarity, span) ...): ties go to the larger span string.
            var best = (0.0, "")
            for span in spans where abs(letters(span).count - w.count) <= max(3, w.count / 2) {
                let candidate = (similarity(word, span), span)
                if candidate > best { best = candidate }
            }
            if best.0 < threshold { continue }
            let span = best.1
            // The recogniser already wrote a different-sounding name here: trust it.
            if !span.contains(" "), span.first?.isUppercase == true, !inDictionary(span), sound(span) != sound(word) {
                continue
            }
            scored.append((best.0, word))
        }
        // Python's sort is stable; so is this one, by score only.
        let ordered = scored.enumerated().sorted { ($1.element.0, $0.offset) < ($0.element.0, $1.offset) }
        return ordered.prefix(limit).map(\.element.1)
    }

    /// The section added to the cleanup request, before RAW_TRANSCRIPTION.
    static func promptSection(_ words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        return "SCREEN_WORDS (spellings visible on the user's screen, as read by OCR; may contain misreads): "
            + words.joined(separator: ", ") + "\n"
            + "Use a SCREEN_WORDS spelling only to replace a word or phrase in RAW_TRANSCRIPTION that is clearly a "
            + "mis-hearing of it, for example a name or technical term heard as ordinary words. Replace only what was "
            + "misheard: never add a screen word that was not spoken (such as a surname next to a spoken first name), "
            + "and keep ordinary words that make sense as they are.\n"
    }
}
