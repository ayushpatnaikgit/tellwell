import Accelerate
import Foundation

/// Parakeet's joint network on the CPU, returning every score, for vocabulary boosting.
///
/// The Core ML joint model (JointDecision) returns only its pick, so it can't be boosted. Its weights are plain fp16
/// blocks in its weights/weight.bin, at offsets its model.mil names; this reads the same weights (the downloaded,
/// checksum-verified file, unchanged) and computes
///   scores = W2 · relu(We · encoder + be + Wp · decoder + bp) + b2
/// with Accelerate: 1,030 scores per step, the 1,025 token scores (1,024 word-pieces, then blank) followed by the 5
/// duration scores. About 0.7 M multiply-adds a step, so the boosted pass costs a few milliseconds per window.
final class JointScores: @unchecked Sendable {  // used only on the engine's serial work queue
    static let encoderWidth = 1024, hidden = 640, outputs = 1030, tokens = 1025

    private let encW: [Float], encB: [Float], predW: [Float], predB: [Float], outW: [Float], outB: [Float]

    enum LoadError: Error { case missing(String), badBlob(String) }

    /// Weight name -> (shape, byte offset of the blob header in weight.bin), from model.mil's const ops.
    static func blobOffsets(mil: String) -> [String: (shape: [Int], offset: Int)] {
        let pattern = #"tensor<fp16, \[([0-9, ]+)\]> ([A-Za-z0-9_]+) = const\(\)\[name = tensor<string, \[\]>\("[^"]*"\), val = tensor<fp16, \[[0-9, ]+\]>\(BLOBFILE\(path = tensor<string, \[\]>\("@model_path/weights/weight\.bin"\), offset = tensor<uint64, \[\]>\(([0-9]+)\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = mil as NSString
        var out: [String: (shape: [Int], offset: Int)] = [:]
        for m in re.matches(in: mil, range: NSRange(location: 0, length: ns.length)) {
            let shape = ns.substring(with: m.range(at: 1)).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let offset = Int(ns.substring(with: m.range(at: 3))) { out[ns.substring(with: m.range(at: 2))] = (shape, offset) }
        }
        return out
    }

    /// The fp16 values of one blob as Float. A blob starts with a 64-byte header: 0xDEADBEEF, the data type
    /// (1 = fp16), the data size in bytes and the data's absolute offset.
    static func readBlob(_ data: Data, at offset: Int, count: Int) throws -> [Float] {
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u64(_ at: Int) -> UInt64 { data[at..<at + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        guard offset >= 0, offset + 24 <= data.count, u32(offset) == 0xDEAD_BEEF, u32(offset + 4) == 1,
              Int(u64(offset + 8)) == count * 2 else { throw LoadError.badBlob("header at \(offset)") }
        let start = Int(u64(offset + 16))
        guard start >= 0, start + count * 2 <= data.count else { throw LoadError.badBlob("data at \(start)") }
        return data[start..<start + count * 2].withUnsafeBytes { raw in
            (0..<count).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Float16.self)) }
        }
    }

    init(mil: String, weights: Data) throws {
        let blobs = Self.blobOffsets(mil: mil)
        func load(_ suffix: String, _ shape: [Int]) throws -> [Float] {
            guard let blob = blobs.first(where: { $0.key.hasSuffix(suffix) })?.value, blob.shape == shape else {
                throw LoadError.missing(suffix)
            }
            return try Self.readBlob(weights, at: blob.offset, count: shape.reduce(1, *))
        }
        let h = Self.hidden
        encW = try load("enc_weight_to_fp16", [h, Self.encoderWidth])
        encB = try load("enc_bias_to_fp16", [h])
        predW = try load("pred_weight_to_fp16", [h, h])
        predB = try load("pred_bias_to_fp16", [h])
        outW = try load("joint_net_2_weight_to_fp16", [Self.outputs, h])
        outB = try load("joint_net_2_bias_to_fp16", [Self.outputs])
    }

    convenience init(modelDirectory: URL) throws {
        let mil = try String(contentsOf: modelDirectory.appendingPathComponent("model.mil"), encoding: .utf8)
        let weights = try Data(contentsOf: modelDirectory.appendingPathComponent("weights/weight.bin"), options: .mappedIfSafe)
        try self.init(mil: mil, weights: weights)
    }

    /// The encoder side for all frames at once: `encoded` is [1024 x frames], row-major. Returns [frames x 640].
    func encoderProjection(_ encoded: [Float], frames: Int) -> [Float] {
        let h = Self.hidden
        var hf = [Float](repeating: 0, count: h * frames)          // [640 x frames]
        vDSP_mmul(encW, 1, encoded, 1, &hf, 1, vDSP_Length(h), vDSP_Length(frames), vDSP_Length(Self.encoderWidth))
        var out = [Float](repeating: 0, count: frames * h)          // transpose, add bias
        for t in 0..<frames {
            for k in 0..<h { out[t * h + k] = hf[k * frames + t] + encB[k] }
        }
        return out
    }

    /// The decoder side for one decoder output (640 values).
    func decoderProjection(_ decoder: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: Self.hidden)
        vDSP_mmul(predW, 1, decoder, 1, &out, 1, vDSP_Length(Self.hidden), 1, vDSP_Length(Self.hidden))
        vDSP_vadd(out, 1, predB, 1, &out, 1, vDSP_Length(Self.hidden))
        return out
    }

    /// All 1,030 scores for frame `t` of an encoder projection and a decoder projection.
    func scores(encoder: [Float], frame t: Int, decoder: [Float]) -> [Float] {
        let h = Self.hidden
        var hidden = [Float](repeating: 0, count: h)
        encoder.withUnsafeBufferPointer { e in
            vDSP_vadd(e.baseAddress! + t * h, 1, decoder, 1, &hidden, 1, vDSP_Length(h))
        }
        var zero: Float = 0
        vDSP_vthres(hidden, 1, &zero, &hidden, 1, vDSP_Length(h))   // relu
        var out = [Float](repeating: 0, count: Self.outputs)
        vDSP_mmul(outW, 1, hidden, 1, &out, 1, vDSP_Length(Self.outputs), 1, vDSP_Length(h))
        vDSP_vadd(out, 1, outB, 1, &out, 1, vDSP_Length(Self.outputs))
        return out
    }
}
