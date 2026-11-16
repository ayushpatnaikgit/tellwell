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
    private let windowSamples = 15 * 16_000
    private let strideSamples = 12 * 16_000
    private let secondsPerFrame = 0.08                 // 10 ms mel hop x 8 subsampling
    private let encoderWidth = 1024, decoderWidth = 640, decoderLayers = 2
    private let maxSymbolsPerFrame = 10

    private struct Token { let id: Int; let time: Double }

    private let pre, enc, dec, joint: MLModel
    private let vocab: [String]
    private var blank: Int32 { Int32(vocab.count) }

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
    }

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

    /// Greedy TDT decoding of one window (at most 15 s). Token times are relative to the window.
    private func window(_ samples: ArraySlice<Float>) throws -> [Token] {
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
                    tokens.append(Token(id: Int(token), time: Double(t) * secondsPerFrame))
                    (decoderOut, h, c) = try decoderStep(token, h, c)
                }
                t += duration
                symbols += 1
                if duration != 0 { symbols = 0 } else if symbols >= maxSymbolsPerFrame { t += 1; symbols = 0 }
            }
        }
        return tokens
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard samples.count >= 160 else { return "" }
        var all: [WindowStitch.Token] = []
        var start = 0
        while true {
            let end = min(start + windowSamples, samples.count)
            let offset = Double(start) / Double(Self.sampleRate)
            let tokens = try window(samples[start..<end]).map { WindowStitch.Token(id: $0.id, time: $0.time + offset) }
            if start == 0 {
                all = tokens
            } else {
                let midpoint = offset + Double(windowSamples - strideSamples) / Double(Self.sampleRate) / 2
                all = WindowStitch.join(all, tokens, midpoint: midpoint, vocab: vocab)
            }
            if end == samples.count { break }
            start += strideSamples
        }
        return all.map { vocab[$0.id] }.joined().replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
