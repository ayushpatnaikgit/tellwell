import Foundation

/// The two-pass rules (Sources/Engine/TwoPass.swift) must give exactly the answers of the lab code they were measured
/// with. Tests/Fixtures/two-pass-golden.json holds that code's outputs on synthetic dictations (invented sentences
/// spoken by macOS voices), at two flag levels.
enum TwoPassTests {
    static func run() {
        let url = URL(fileURLWithPath: "Tests/Fixtures/two-pass-golden.json")
        guard let data = try? Data(contentsOf: url),
              let golden = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            fatalError("missing Tests/Fixtures/two-pass-golden.json (run tests from the repository root)")
        }
        for c in golden["normalise"] ?? [] {
            TestSupport.expectEqual(TwoPass.normalise(c["text"] as! String), c["tokens"] as! [String])
        }
        for c in golden["cases"] ?? [] {
            let heard = c["heard"] as! String, cleaned = c["cleaned"] as! String
            let flags = c["flags"] as! [Bool], terms = c["terms"] as! [String]
            TestSupport.expectEqual(TwoPass.gate(heard: heard, cleaned: cleaned, flags: flags, terms: terms),
                                    c["gated"] as! String)
            TestSupport.expectEqual(TwoPass.canSkipCleanup(heard: heard, flags: flags, terms: terms), c["skip"] as! Bool)
        }

        // Hand-written cases.
        let swap = TwoPass.gate(heard: "Send it to the team today.", cleaned: "Send it to the group today.",
                                flags: [false, false, false, false, false, false])
        TestSupport.expectEqual(swap, "Send it to the team today.")
        let flagged = TwoPass.gate(heard: "Send it to the team today.", cleaned: "Send it to the group today.",
                                   flags: [false, false, false, false, true, false])
        TestSupport.expectEqual(flagged, "Send it to the group today.")
        let correction = TwoPass.gate(heard: "Meet on Thursday, no actually Wednesday.", cleaned: "Meet on Wednesday.",
                                      flags: [Bool](repeating: false, count: 6))
        TestSupport.expectEqual(correction, "Meet on Wednesday.")
        let dropped = TwoPass.gate(heard: "The report is done and the budget was approved yesterday.",
                                   cleaned: "The report is done yesterday.", flags: [Bool](repeating: false, count: 10))
        TestSupport.expect(dropped.contains("budget was approved"), "an unexplained dropped clause is put back")
        TestSupport.expectEqual(TwoPass.gate(heard: "a b", cleaned: "c", flags: [true]), "c")  // mismatched flags: unchanged
        let offTheRails = TwoPass.gate(heard: "Thanks Sam, this looks good.", cleaned:
                                       "Thanks Sam. The pull request is titled Fix idle unload and they are leaving review feedback.",
                                       flags: [Bool](repeating: false, count: 5))
        TestSupport.expectEqual(offTheRails, "Thanks Sam, this looks good.")

        TestSupport.expect(TwoPass.canSkipCleanup(heard: "See you at the station.", flags: [false, false, false, false, false]),
                           "a clean sentence skips cleanup")
        TestSupport.expect(!TwoPass.canSkipCleanup(heard: "See you, um, at the station.", flags: [Bool](repeating: false, count: 6)),
                           "fillers need cleanup")
        TestSupport.expect(!TwoPass.canSkipCleanup(heard: "See you at the station.", flags: [false, false, false, true, false]),
                           "a flagged word needs cleanup")
        TestSupport.expect(!TwoPass.canSkipCleanup(heard: "see you at the station", flags: [Bool](repeating: false, count: 5)),
                           "no punctuation needs cleanup")
        TestSupport.expect(!TwoPass.canSkipCleanup(heard: "Ask Sid hunt to look.", flags: [Bool](repeating: false, count: 5),
                                                   terms: ["Siddhant"]), "a near-miss of a listed name needs cleanup")
        TestSupport.expect(!TwoPass.canSkipCleanup(heard: "We store the embeddings in post gress.", flags: [Bool](repeating: false, count: 6),
                                                   terms: ["Postgres"]), "a term inside a longer heard word is not spelled out")
        TestSupport.expect(!TwoPass.canSkipCleanup(heard: "On se voit jeudi, non, vendredi à midi.", flags: [Bool](repeating: false, count: 8)),
                           "non-English text needs cleanup")

        // Flags follow words through filler stripping.
        TestSupport.expectEqual(TwoPass.flags(for: "So the cash is stale.", heard: ["So", "um", "the", "cash", "is", "stale."],
                                              heardFlags: [false, false, false, true, false, false]),
                                [false, false, true, false, false])

        // "<unk>" runs.
        typealias T = WindowStitch.Token
        TestSupport.expect(WindowStitch.hasUnknownRun([T(id: 5, time: 0), T(id: 0, time: 0.1), T(id: 0, time: 0.2), T(id: 0, time: 0.3)]),
                           "three <unk> pieces are a failed decode")
        TestSupport.expect(!WindowStitch.hasUnknownRun([T(id: 0, time: 0), T(id: 5, time: 0.1), T(id: 0, time: 0.2)]),
                           "scattered <unk> pieces are not")

        // Labeller arithmetic.
        let lab = TwoPass.Labeller(mean: [0, 0, 0, 0], scale: [1, 1, 1, 1], weights: [0, 0, 1, -1], bias: 0, threshold: 0.5)
        let f = WindowStitch.WordFeatures(mean: [2, 0], frames: 0, pause: 0)
        TestSupport.expectApproximatelyEqual(Double(lab.probability(f)), 1 / (1 + exp(-2)))
        TestSupport.expectEqual(lab.flags([("a", f), ("b", nil)]), [true, false])
    }
}
