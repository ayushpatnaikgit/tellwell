import Foundation

/// A port of Python's `difflib.SequenceMatcher` (no junk function), so the engine's similarity scores and word
/// alignments match the Python engine they were tuned with exactly.
struct SequenceMatcher<Element: Hashable> {
    struct Match: Equatable {
        let a: Int, b: Int, size: Int
    }

    enum Tag: String { case replace, delete, insert, equal }

    struct Opcode: Equatable {
        let tag: Tag
        let i1: Int, i2: Int, j1: Int, j2: Int
    }

    let a: [Element]
    let b: [Element]
    private let b2j: [Element: [Int]]

    /// `autojunk` drops elements of `b` that occur in more than 1% of a sequence of 200 or more, like Python.
    init(_ a: [Element], _ b: [Element], autojunk: Bool = true) {
        self.a = a
        self.b = b
        var b2j: [Element: [Int]] = [:]
        for (i, element) in b.enumerated() {
            b2j[element, default: []].append(i)
        }
        let n = b.count
        if autojunk && n >= 200 {
            let ntest = n / 100 + 1
            for (element, indices) in b2j where indices.count > ntest {
                b2j.removeValue(forKey: element)
            }
        }
        self.b2j = b2j
    }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Match {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        // Extend over equal elements (including "popular" ones the index left out); there is no junk here.
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1
            bestj -= 1
            bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return Match(a: besti, b: bestj, size: bestsize)
    }

    func matchingBlocks() -> [Match] {
        let la = a.count, lb = b.count
        var queue = [(0, la, 0, lb)]
        var blocks: [Match] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let m = findLongestMatch(alo, ahi, blo, bhi)
            if m.size > 0 {
                blocks.append(m)
                if alo < m.a && blo < m.b { queue.append((alo, m.a, blo, m.b)) }
                if m.a + m.size < ahi && m.b + m.size < bhi { queue.append((m.a + m.size, ahi, m.b + m.size, bhi)) }
            }
        }
        blocks.sort { ($0.a, $0.b, $0.size) < ($1.a, $1.b, $1.size) }
        var collapsed: [Match] = []
        var i1 = 0, j1 = 0, k1 = 0
        for block in blocks {
            if i1 + k1 == block.a && j1 + k1 == block.b {
                k1 += block.size
            } else {
                if k1 > 0 { collapsed.append(Match(a: i1, b: j1, size: k1)) }
                (i1, j1, k1) = (block.a, block.b, block.size)
            }
        }
        if k1 > 0 { collapsed.append(Match(a: i1, b: j1, size: k1)) }
        collapsed.append(Match(a: la, b: lb, size: 0))
        return collapsed
    }

    func ratio() -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1.0 }
        let matches = matchingBlocks().reduce(0) { $0 + $1.size }
        return 2.0 * Double(matches) / Double(total)
    }

    func opcodes() -> [Opcode] {
        var i = 0, j = 0
        var out: [Opcode] = []
        for m in matchingBlocks() {
            let tag: Tag?
            if i < m.a && j < m.b { tag = .replace } else if i < m.a { tag = .delete } else if j < m.b { tag = .insert } else { tag = nil }
            if let tag { out.append(Opcode(tag: tag, i1: i, i2: m.a, j1: j, j2: m.b)) }
            i = m.a + m.size
            j = m.b + m.size
            if m.size > 0 { out.append(Opcode(tag: .equal, i1: m.a, i2: i, j1: m.b, j2: j)) }
        }
        return out
    }
}

extension SequenceMatcher where Element == Character {
    init(_ a: String, _ b: String, autojunk: Bool = true) {
        self.init(Array(a), Array(b), autojunk: autojunk)
    }
}
