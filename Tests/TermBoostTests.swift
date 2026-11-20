import Foundation

/// Vocabulary boosting in the speech recogniser and the CPU joint it scores with. Invented word-pieces, scores and
/// weights; no model files.
enum TermBoostTests {
    // Word-pieces; the blank ("nothing said") is the id after the last one.
    private static let vocab = ["▁sid", "d", "hant", "▁city", "▁the", "▁loop", "▁in", "▁gra", "fana", "▁graph"]
    private static let blank = vocab.count
    private static let pieces = TermBoost.pieces(vocab)
    private static func t(_ id: Int, _ time: Double) -> WindowStitch.Token { WindowStitch.Token(id: id, time: time) }
    private static func text(_ tokens: [WindowStitch.Token]) -> String {
        tokens.map { vocab[$0.id] }.joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }
    /// Raw scores: every token far below, except the ones given.
    private static func scores(_ set: [Int: Float]) -> [Float] {
        (0...blank).map { set[$0] ?? -30 }
    }

    static func run() {
        termList()
        choice()
        wholeTerms()
        jointScores()
    }

    private static func termList() {
        TestSupport.expectEqual(TermBoost.vocabulary("Siddhant, Kavya\nGrafana; ;  "), ["Siddhant", "Kavya", "Grafana"])
        // Vocabulary first; duplicates (any case) and terms under 3 letters or digits dropped.
        TestSupport.expectEqual(TermBoost.terms(vocabulary: ["Siddhant", "AI"], screen: ["siddhant", "Kavya", "M4"]),
                                ["Siddhant", "Kavya"])
        TestSupport.expectEqual(TermBoost.terms(vocabulary: (0..<150).map { "Term\($0)" }, screen: []).count,
                                TermBoost.maxTerms)
        TestSupport.expect(!TermBoost(terms: [" "]).isOn, "a blank term list must not boost")
    }

    private static func choice() {
        let boost = TermBoost(terms: ["Siddhant"])
        var active = Set<TermBoost.Partial>()

        // A close call: "city" is the model's pick, "sid" (the start of a listed name) is close behind.
        let first = boost.choose(scores([3: 0, 0: -1.5]), stock: 3, blank: blank, pieces: pieces, active: &active)
        TestSupport.expectEqual(first, 0)
        // Mid-name, the piece that continues it wins over an unrelated one.
        let second = boost.choose(scores([4: 0, 1: -2]), stock: 4, blank: blank, pieces: pieces, active: &active)
        TestSupport.expectEqual(second, 1)
        let third = boost.choose(scores([4: 0, 2: -2]), stock: 4, blank: blank, pieces: pieces, active: &active)
        TestSupport.expectEqual(third, 2)

        // Never boost a piece the model finds implausible.
        var fresh = Set<TermBoost.Partial>()
        TestSupport.expectEqual(boost.choose(scores([3: 0, 0: -9]), stock: 3, blank: blank, pieces: pieces, active: &fresh), 3)
        // Never turn "nothing said here" into speech unless the piece was already close to it.
        TestSupport.expectEqual(boost.choose(scores([blank: 0, 0: -5]), stock: blank, blank: blank, pieces: pieces,
                                             active: &fresh), blank)
        TestSupport.expectEqual(boost.choose(scores([blank: 0, 0: -2]), stock: blank, blank: blank, pieces: pieces,
                                             active: &fresh), 0)
    }

    private static func wholeTerms() {
        let boost = TermBoost(terms: ["Siddhant", "Grafana"])
        let stock = [t(5, 0.0), t(6, 0.3), t(3, 0.6)]                                   // "loop in city"

        // The boosted pass spelled the whole name where "city" was heard: it replaces it.
        let (swapped, count) = boost.acceptTerms(stock: stock, boosted: [t(5, 0.0), t(6, 0.3), t(0, 0.6), t(1, 0.7), t(2, 0.8)],
                                                 pieces: pieces)
        TestSupport.expectEqual(text(swapped), "loop in siddhant")
        TestSupport.expectEqual(count, 1)
        TestSupport.expectEqual(boost.spellTerms(text(swapped)), "loop in Siddhant")

        // Half a name ("sidd") is not a listed term: the ordinary words stay.
        let (partial, none) = boost.acceptTerms(stock: stock, boosted: [t(5, 0.0), t(6, 0.3), t(0, 0.6), t(1, 0.7)], pieces: pieces)
        TestSupport.expectEqual(text(partial), "loop in city")
        TestSupport.expectEqual(none, 0)

        // A term the boosted pass found where the ordinary pass heard nothing is never inserted.
        let (silence, _) = boost.acceptTerms(stock: stock, boosted: stock + [t(7, 2.0), t(8, 2.1)], pieces: pieces)
        TestSupport.expectEqual(text(silence), "loop in city")

        // Casing only for whole words: "graph" stays, "grafana" takes the listed spelling.
        TestSupport.expectEqual(boost.spellTerms("the graph in grafana"), "the graph in Grafana")
    }

    // MARK: - CPU joint

    private static func blob(_ values: [Float], into data: inout Data) -> Int {
        let offset = data.count
        var header = Data(count: 64)
        header.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0xDEAD_BEEF), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt64(values.count * 2), toByteOffset: 8, as: UInt64.self)
            raw.storeBytes(of: UInt64(offset + 64), toByteOffset: 16, as: UInt64.self)
        }
        data.append(header)
        for v in values { withUnsafeBytes(of: Float16(v)) { data.append(contentsOf: $0) } }
        return offset
    }

    private static func milLine(_ name: String, _ shape: [Int], _ offset: Int) -> String {
        let s = "[" + shape.map(String.init).joined(separator: ", ") + "]"
        return "tensor<fp16, \(s)> \(name) = const()[name = tensor<string, []>(\"\(name)\"), val = tensor<fp16, \(s)>(BLOBFILE(path = tensor<string, []>(\"@model_path/weights/weight.bin\"), offset = tensor<uint64, []>(\(offset))))];"
    }

    private static func jointScores() {
        let h = JointScores.hidden, e = JointScores.encoderWidth, o = JointScores.outputs
        func model(encoderBias: Float) throws -> JointScores {
            var data = Data(count: 64)
            var mil: [String] = []
            func add(_ name: String, _ shape: [Int], _ values: [Float]) {
                mil.append(milLine("joint_module_" + name, shape, blob(values, into: &data)))
            }
            add("enc_weight_to_fp16", [h, e], [Float](repeating: 0, count: h * e))
            add("enc_bias_to_fp16", [h], [Float](repeating: encoderBias, count: h))
            add("pred_weight_to_fp16", [h, h], [Float](repeating: 0, count: h * h))
            add("pred_bias_to_fp16", [h], [Float](repeating: 0, count: h))
            add("joint_net_2_weight_to_fp16", [o, h], (0..<(o * h)).map { $0 < h ? 1 : 0 })   // row 0 sums the hidden layer
            add("joint_net_2_bias_to_fp16", [o], (0..<o).map { Float($0 % 7) / 2 })
            return try JointScores(mil: mil.joined(separator: "\n"), weights: data)
        }
        do {
            let positive = try model(encoderBias: 1)
            let enc = positive.encoderProjection([Float](repeating: 0, count: e * 2), frames: 2)
            let dec = positive.decoderProjection([Float](repeating: 0, count: h))
            let s = positive.scores(encoder: enc, frame: 1, decoder: dec)
            TestSupport.expectEqual(s.count, o)
            TestSupport.expectApproximatelyEqual(Double(s[0]), Double(h))          // 640 hidden units of 1, plus bias 0
            TestSupport.expectApproximatelyEqual(Double(s[3]), 1.5)                 // bias only
            // A negative hidden layer is cut to zero (relu), leaving the bias.
            let negative = try model(encoderBias: -1)
            let n = negative.scores(encoder: negative.encoderProjection([Float](repeating: 0, count: e), frames: 1), frame: 0,
                                    decoder: negative.decoderProjection([Float](repeating: 0, count: h)))
            TestSupport.expectApproximatelyEqual(Double(n[0]), 0)
        } catch {
            TestSupport.expect(false, "synthetic joint weights failed to load: \(error)")
        }

        // A damaged weight file is refused, not read as garbage.
        var bad = Data(count: 64)
        let at = blob([1, 2, 3], into: &bad)
        bad[at] = 0
        TestSupport.expect((try? JointScores.readBlob(bad, at: at, count: 3)) == nil, "a blob without its header must be refused")
        TestSupport.expect((try? JointScores(mil: "", weights: Data())) == nil, "missing weights must be refused")
    }
}
