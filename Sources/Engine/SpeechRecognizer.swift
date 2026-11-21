import AVFoundation
import CoreML
import Foundation

/// Speech to text with NVIDIA Parakeet TDT 0.6B v2 (English) on the Neural Engine, through Core ML.
///
/// The model takes fixed 15 s windows. Longer audio is split into windows overlapping by 3 s and stitched at the word
/// boundary nearest the middle of each overlap, using token timestamps (WindowStitch). (From freeflow-local's Neural Engine helper,
/// adapted to FluidInference's v2 Core ML bundle.) Audio stays in memory.
final class SpeechRecognizer: @unchecked Sendable {  // used only on the engine's serial work queue
    static let sampleRate = 16_000
    /// Recognition windows: 15 s long, one every 12 s (in samples).
    static let windowLength = 15 * 16_000
    static let windowStep = 12 * 16_000
    private let windowSamples = SpeechRecognizer.windowLength
    private let strideSamples = SpeechRecognizer.windowStep
    private let secondsPerFrame = 0.08                 // 10 ms mel hop x 8 subsampling
    private let encoderWidth = 1024, decoderWidth = 640, decoderLayers = 2
    private let maxSymbolsPerFrame = 10

    private typealias Token = WindowStitch.Token

    private let pre, enc, dec, joint: MLModel
    private let vocab: [String]
    private var blank: Int32 { Int32(vocab.count) }
    /// The joint network on the CPU with all its scores, for vocabulary boosting (nil if its weights can't be read).
    private let jointScores: JointScores?
    private let pieces: [[Character]]
    /// Words swapped in by boosting in the last transcription (a count only, for the benchmark).
    private(set) var boostedWords = 0

    init(directory: URL) throws {
        func model(_ name: String) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            return try MLModel(contentsOf: directory.appendingPathComponent("\(name).mlmodelc"), configuration: config)
        }
        pre = try model("Preprocessor")
        enc = try model("Encoder")
        dec = try model("Decoder")
        joint = try model("JointDecision")
        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard let v = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Parakeet v2 has 1,024 word-pieces and the blank ("nothing said") is id 1024. The bundle's vocabulary file
        // carries 7 extra entries after them, which the model never produces: ignore them.
        vocab = (0..<min(v.count, 1024)).map { v[String($0)] ?? "" }
        pieces = TermBoost.pieces(vocab)
        jointScores = try? JointScores(modelDirectory: directory.appendingPathComponent("JointDecision.mlmodelc"))
    }

    /// Whether vocabulary boosting is available (the joint's weights were read and match the vocabulary).
    var canBoost: Bool { jointScores != nil && vocab.count + 1 == JointScores.tokens }

    /// Builds the Neural Engine kernels now, so the first dictation isn't slow.
    func warmUp() throws { _ = try transcribe([Float](repeating: 0, count: Self.sampleRate)) }

    // MARK: - Audio

    /// Any audio file as 16 kHz mono Float32 samples.
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let inputCapacity = AVAudioFrameCount(min(file.length, 1 << 22))
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(inputCapacity, 1)) else { return [] }
        var out: [Float] = []
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1 << 16) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                do {
                    try file.read(into: input)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let channel = output.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            finished = status == .endOfStream || status == .error || output.frameLength == 0
        }
        return out
    }

    // MARK: - Recognition

    private func array(_ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    }

    private func zeros(_ shape: [Int]) throws -> MLMultiArray {
        let a = try array(shape, .float32)
        a.withUnsafeMutableBufferPointer(ofType: Float.self) { b, _ in b.initialize(repeating: 0) }
        return a
    }

    private func decoderStep(_ token: Int32, _ h: MLMultiArray, _ c: MLMultiArray) throws -> (MLMultiArray, MLMultiArray, MLMultiArray) {
        let targets = try array([1, 1], .int32); targets[0] = NSNumber(value: token)
        let length = try array([1], .int32); length[0] = 1
        let o = try dec.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": targets, "target_length": length, "h_in": h, "c_in": c]))
        return (o.featureValue(for: "decoder")!.multiArrayValue!, o.featureValue(for: "h_out")!.multiArrayValue!,
                o.featureValue(for: "c_out")!.multiArrayValue!)
    }

    /// One window (at most 15 s): the ordinary pass, plus whole listed terms from a boosted pass when `boost` is set.
    /// Token times are relative to the window.
    private func window(_ samples: ArraySlice<Float>, boost: TermBoost?) throws -> [Token] {
        let audio = try array([1, windowSamples], .float32)
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
            buf.initialize(repeating: 0)
            for (i, s) in samples.enumerated() { buf[i] = s }
        }
        let audioLength = try array([1], .int32); audioLength[0] = NSNumber(value: samples.count)
        let p = try pre.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio_signal": audio, "audio_length": audioLength]))
        let e = try enc.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": p.featureValue(for: "mel")!, "mel_length": p.featureValue(for: "mel_length")!]))
        let encoded = e.featureValue(for: "encoder")!.multiArrayValue!               // [1, 1024, T]
        let frames = min(e.featureValue(for: "encoder_length")!.multiArrayValue![0].intValue, encoded.shape[2].intValue)
        var checkpoints: [Checkpoint] = []
        let stock = try decode(encoded, frames, checkpoints: &checkpoints)
        guard let boost, boost.isOn, canBoost else { return stock }
        // Second pass with boosting (the encoder output is reused). Only whole listed terms are taken from it.
        let boosted: [Token]
        if boost.beam > 1 {
            // Only around heard words a listed term could replace: a word before to two after, starting from the
            // ordinary pass's decoder state there. Elsewhere the result would be discarded anyway.
            let runs = boost.candidateRuns(stock: stock, pieces: pieces)
            guard !runs.isEmpty else { return stock }
            let words = TermBoost.words(stock, pieces: pieces)
            var spans: [(from: Int, to: Int)] = []                    // word ranges, merged
            for run in runs {
                let span = (from: max(0, run.lowerBound - 1), to: min(words.count, run.upperBound + 3))
                if let last = spans.last, span.from <= last.to { spans[spans.count - 1].to = max(last.to, span.to) }
                else { spans.append(span) }
            }
            let encoderSide = try encoderSide(encoded, frames)
            var spliced: [Token] = []
            var next = 0                                               // next stock token to copy
            for span in spans {
                let start = checkpoints[span.from]
                let endToken = span.to < words.count ? words[span.to].0 : stock.count
                let endFrame = span.to < words.count ? checkpoints[span.to].frame : frames
                spliced += stock[next..<start.token]
                spliced += try decodeBeam(encoderSide, from: start, to: endFrame, boost)
                next = endToken
            }
            boosted = spliced + stock[next...]
        } else {
            boosted = try decodeBoosted(encoded, frames, boost)
        }
        let (tokens, swapped) = boost.acceptTerms(stock: stock, boosted: boosted, pieces: pieces)
        boostedWords += swapped
        return tokens
    }

    /// The decoder's state just before a word was emitted by the ordinary pass, so the boosted pass can start there.
    private struct Checkpoint { let token: Int; let frame: Int; let out, h, c: MLMultiArray }

    /// Greedy TDT decoding over encoder frames with the Core ML joint (on the Neural Engine). `checkpoints` gets the
    /// decoder state at the start of every word.
    private func decode(_ encoded: MLMultiArray, _ frames: Int, checkpoints: inout [Checkpoint]) throws -> [Token] {
        let s1 = encoded.strides[1].intValue, s2 = encoded.strides[2].intValue
        var (decoderOut, h, c) = try decoderStep(blank, try zeros([decoderLayers, 1, decoderWidth]), try zeros([decoderLayers, 1, decoderWidth]))
        let step = try array([1, encoderWidth, 1], .float32)
        var tokens: [Token] = []
        var t = 0, symbols = 0
        try encoded.withUnsafeBufferPointer(ofType: Float.self) { src in
            while t < frames {
                step.withUnsafeMutableBufferPointer(ofType: Float.self) { dst, _ in
                    for k in 0..<encoderWidth { dst[k] = src[k * s1 + t * s2] }
                }
                let j = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: ["encoder_step": step, "decoder_step": decoderOut]))
                let token = j.featureValue(for: "token_id")!.multiArrayValue![0].int32Value
                let duration = j.featureValue(for: "duration")!.multiArrayValue![0].intValue
                if token != blank {
                    let prob = j.featureValue(for: "token_prob")?.multiArrayValue?[0].floatValue ?? 1
                    if tokens.isEmpty || pieces[Int(token)].first == "▁" {
                        checkpoints.append(Checkpoint(token: tokens.count, frame: t, out: decoderOut, h: h, c: c))
                    }
                    tokens.append(Token(id: Int(token), time: Double(t) * secondsPerFrame, prob: prob))
                    (decoderOut, h, c) = try decoderStep(token, h, c)
                }
                t += duration
                symbols += 1
                if duration != 0 { symbols = 0 } else if symbols >= maxSymbolsPerFrame { t += 1; symbols = 0 }
            }
        }
        return tokens
    }

    /// Greedy TDT decoding with vocabulary boosting, scoring with the joint network on the CPU.
    private func decodeBoosted(_ encoded: MLMultiArray, _ frames: Int, _ boost: TermBoost) throws -> [Token] {
        guard let jointScores, frames > 0 else { return [] }
        let s1 = encoded.strides[1].intValue, s2 = encoded.strides[2].intValue
        var flat = [Float](repeating: 0, count: encoderWidth * frames)       // [1024 x frames], row-major
        encoded.withUnsafeBufferPointer(ofType: Float.self) { src in
            for k in 0..<encoderWidth { for t in 0..<frames { flat[k * frames + t] = src[k * s1 + t * s2] } }
        }
        let encoderSide = jointScores.encoderProjection(flat, frames: frames)
        func decoderSide(_ out: MLMultiArray) -> [Float] {
            let stride = out.strides[1].intValue
            return out.withUnsafeBufferPointer(ofType: Float.self) { b in (0..<decoderWidth).map { b[$0 * stride] } }
        }
        func argmax(_ a: ArraySlice<Float>) -> Int { a.indices.max { a[$0] < a[$1] }! - a.startIndex }

        var (decoderOut, h, c) = try decoderStep(blank, try zeros([decoderLayers, 1, decoderWidth]), try zeros([decoderLayers, 1, decoderWidth]))
        var decoded = jointScores.decoderProjection(decoderSide(decoderOut))
        var tokens: [Token] = []
        var active = Set<TermBoost.Partial>()
        var t = 0, symbols = 0
        while t < frames {
            let scores = jointScores.scores(encoder: encoderSide, frame: t, decoder: decoded)
            let tokenScores = Array(scores[0..<JointScores.tokens])
            let stock = argmax(tokenScores[...])
            let token = boost.choose(tokenScores, stock: stock, blank: Int(blank), pieces: pieces, active: &active)
            let duration = argmax(scores[JointScores.tokens...])
            if token != Int(blank) {
                tokens.append(Token(id: token, time: Double(t) * secondsPerFrame))
                (decoderOut, h, c) = try decoderStep(Int32(token), h, c)
                decoded = jointScores.decoderProjection(decoderSide(decoderOut))
            }
            t += duration
            symbols += 1
            if duration != 0 { symbols = 0 } else if symbols >= maxSymbolsPerFrame { t += 1; symbols = 0 }
        }
        return tokens
    }

    // MARK: - Beam search with boosting

    /// One candidate transcript in the beam.
    private struct Hyp {
        var tokens: [Token]
        var score: Float
        var decoded: [Float]                    // the decoder side of the joint for this transcript
        var h: MLMultiArray, c: MLMultiArray
        var active: Set<TermBoost.Partial>
        var credit: Float                       // bonus given to a name still being spelled; taken back if unfinished
        var symbols: Int                        // word-pieces emitted at the current frame
    }

    /// TDT beam search with boosting: keeps `boost.beam` candidate transcripts and lets a listed name compete as a
    /// whole ("Ayush Pat-naik" against "I use for neck") instead of losing it at the first piece. Candidates are
    /// compared only when they have consumed the same audio (bucketed by frame), and the bonus for a name that is
    /// started but not finished is taken back, so half-names don't win on credit.
    /// The encoder side of the CPU joint for every frame of the window.
    private func encoderSide(_ encoded: MLMultiArray, _ frames: Int) throws -> [Float] {
        guard let jointScores, frames > 0 else { return [] }
        let s1 = encoded.strides[1].intValue, s2 = encoded.strides[2].intValue
        var flat = [Float](repeating: 0, count: encoderWidth * frames)
        encoded.withUnsafeBufferPointer(ofType: Float.self) { src in
            for k in 0..<encoderWidth { for t in 0..<frames { flat[k * frames + t] = src[k * s1 + t * s2] } }
        }
        return jointScores.encoderProjection(flat, frames: frames)
    }

    /// Beam search from the ordinary pass's state at `start` until frame `frames`; returns the tokens it adds.
    private func decodeBeam(_ encoderSide: [Float], from start: Checkpoint, to frames: Int, _ boost: TermBoost) throws -> [Token] {
        guard let jointScores, frames > start.frame else { return [] }
        func decoderSide(_ out: MLMultiArray) -> [Float] {
            let stride = out.strides[1].intValue
            return out.withUnsafeBufferPointer(ofType: Float.self) { b in (0..<decoderWidth).map { b[$0 * stride] } }
        }
        func logSoftmax(_ a: ArraySlice<Float>) -> [Float] {
            let top = a.max() ?? 0
            let z = top + log(a.reduce(Float(0)) { $0 + exp($1 - top) })
            return a.map { $0 - z }
        }
        let width = boost.beam
        let blankID = Int(blank)
        func prune(_ hyps: [Hyp]) -> [Hyp] {
            var best: [[Int]: Hyp] = [:]
            for h in hyps {
                let key = h.tokens.map(\.id)
                if let other = best[key], other.score >= h.score { continue }
                best[key] = h
            }
            return Array(best.values.sorted { $0.score > $1.score }.prefix(width))
        }

        var buckets: [Int: [Hyp]] = [start.frame: [Hyp(tokens: [], score: 0, decoded: jointScores.decoderProjection(decoderSide(start.out)),
                                                       h: start.h, c: start.c, active: [], credit: 0, symbols: 0)]]
        var finished: [Hyp] = []
        func place(_ hyp: Hyp, at frame: Int) {
            if frame >= frames { finished.append(hyp) } else { buckets[frame, default: []].append(hyp) }
        }

        for t in start.frame..<frames {
            guard let arriving = buckets.removeValue(forKey: t) else { continue }
            var current = prune(arriving)
            while !current.isEmpty {
                // Expansions of every candidate at this frame; word-pieces wait for the decoder until pruned.
                var pieceCandidates: [(parent: Hyp, id: Int, duration: Int, score: Float,
                                       active: Set<TermBoost.Partial>, credit: Float)] = []
                for hyp in current {
                    let scores = jointScores.scores(encoder: encoderSide, frame: t, decoder: hyp.decoded)
                    let lp = logSoftmax(scores[0..<JointScores.tokens])
                    let dp = logSoftmax(scores[JointScores.tokens...])
                    // Nothing said here: move on by 1-4 frames (the two likeliest).
                    for d in (1..<dp.count).sorted(by: { dp[$0] > dp[$1] }).prefix(2) {
                        var next = hyp
                        next.score += lp[blankID] + dp[d]
                        next.symbols = 0
                        place(next, at: t + d)
                    }
                    // Word-pieces: the likeliest ones, plus any plausible piece that continues a listed name.
                    var ids = Array(lp.indices.filter { $0 != blankID }.sorted { lp[$0] > lp[$1] }.prefix(width))
                    for id in lp.indices where id != blankID && lp[id] >= boost.floor && !ids.contains(id)
                        && boost.advance(hyp.active, pieces[id]) != nil { ids.append(id) }
                    let durations = (0..<dp.count).filter { $0 > 0 || hyp.symbols + 1 < maxSymbolsPerFrame }
                        .sorted { dp[$0] > dp[$1] }.prefix(2)
                    for id in ids where lp[id] >= boost.beamFloor {
                        var bonus: Float, credit: Float, active: Set<TermBoost.Partial>
                        if let next = boost.advance(hyp.active, pieces[id]) {
                            // Continuing a name keeps its credit; starting a new one takes back an abandoned one's.
                            let continuing = next.contains { $0.pos > pieces[id].count }
                            bonus = boost.beta - (continuing ? 0 : hyp.credit); active = next
                            // A finished name keeps its bonus; a name still being spelled holds it on credit.
                            credit = next.contains { $0.pos == boost.keys[$0.term].count }
                                ? 0 : (continuing ? hyp.credit : 0) + boost.beta
                        } else {
                            bonus = -hyp.credit; credit = 0; active = []
                        }
                        for d in durations {
                            pieceCandidates.append((hyp, id, d, hyp.score + lp[id] + dp[d] + bonus, active, credit))
                        }
                    }
                }
                // Only the best few word-piece expansions are kept, so the decoder runs a few times per step.
                pieceCandidates.sort { $0.score > $1.score }
                var sameFrame: [Hyp] = []
                for cand in pieceCandidates.prefix(width) {
                    let (out, h, c) = try decoderStep(Int32(cand.id), cand.parent.h, cand.parent.c)
                    var next = cand.parent
                    next.tokens.append(Token(id: cand.id, time: Double(t) * secondsPerFrame))
                    next.score = cand.score
                    next.decoded = jointScores.decoderProjection(decoderSide(out))
                    next.h = h; next.c = c
                    next.active = cand.active; next.credit = cand.credit
                    if cand.duration == 0 { next.symbols += 1; sameFrame.append(next) } else { next.symbols = 0; place(next, at: t + cand.duration) }
                }
                current = prune(sameFrame)
            }
        }
        for (_, hyps) in buckets { finished += hyps }
        return finished.max { ($0.score - $0.credit) < ($1.score - $1.credit) }?.tokens ?? []
    }

    /// The text of `samples`. `boost` lists names and terms (vocabulary, screen words) to favour; empty = ordinary.
    func transcribe(_ samples: [Float], boost terms: [String] = []) throws -> String {
        try transcribe(samples, using: terms.isEmpty ? nil : TermBoost(terms: terms))
    }

    /// A window decoded earlier: its tokens if it was decoded from exactly these samples at this start, else nil.
    typealias Reuse = (_ start: Int, _ samples: ArraySlice<Float>) -> [WindowStitch.Token]?

    /// Decodes the full window starting at `start` exactly as `transcribe` would, for decoding long dictations while
    /// the user is still speaking. nil if `samples` don't cover the whole window yet.
    func fullWindow(_ samples: [Float], start: Int, using boost: TermBoost?) throws -> [WindowStitch.Token]? {
        guard start >= 0, start + windowSamples <= samples.count else { return nil }
        let boost = canBoost && boost?.isOn == true ? boost : nil
        return try window(samples[start..<(start + windowSamples)], boost: boost)
    }

    /// The text of `samples`, with a configured boost (or none). `reuse` can supply windows decoded earlier.
    func transcribe(_ samples: [Float], using boost: TermBoost?, reuse: Reuse? = nil) throws -> String {
        boostedWords = 0
        guard samples.count >= 160 else { return "" }
        let listed = boost?.terms ?? []
        let boost = canBoost && boost?.isOn == true ? boost : nil
        var all: [WindowStitch.Token] = []
        var start = 0
        while true {
            let end = min(start + windowSamples, samples.count)
            let offset = Double(start) / Double(Self.sampleRate)
            let slice = samples[start..<end]
            let decoded = try reuse?(start, slice) ?? window(slice, boost: boost)
            let tokens = decoded.map { Token(id: $0.id, time: $0.time + offset, prob: $0.prob) }
            if start == 0 {
                all = tokens
            } else {
                let midpoint = offset + Double(windowSamples - strideSamples) / Double(Self.sampleRate) / 2
                all = WindowStitch.join(all, tokens, midpoint: midpoint, vocab: vocab)
            }
            if end == samples.count { break }
            start += strideSamples
        }
        var text = all.map { vocab[$0.id] }.joined().replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !listed.isEmpty else { return text }
        // Words the recogniser was unsure of that sound like a listed name ("Putnamic" -> Patnaik).
        var words: [(String, Float)] = []
        for token in all {
            let piece = vocab[token.id]
            if piece.hasPrefix("▁") || piece.hasPrefix(" ") || words.isEmpty {
                words.append((String(piece.drop(while: { $0 == "▁" || $0 == " " })), token.prob))
            } else {
                words[words.count - 1].0 += piece
                words[words.count - 1].1 = min(words[words.count - 1].1, token.prob)
            }
        }
        let (corrected, fixed) = TermBoost.correctNames(words, terms: listed)
        if fixed > 0 { text = corrected; boostedWords += fixed }
        return TermBoost(terms: listed).spellTerms(text)
    }
}
