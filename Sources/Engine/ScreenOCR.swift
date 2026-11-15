import AppKit
import CoreImage
import Vision

/// Reads the text in the context screenshot with Apple's Vision framework, on this Mac.
///
/// The screenshot is the active window scaled to 1024 px on its longest side, so editor text is only 8-9 px tall.
/// Vision's accurate recogniser misses much of that, and on dark themes often returns nothing. Reading the image
/// upscaled 2x in overlapping tiles, both as is and with inverted colours, recovers most of it (synthetic windows:
/// 305/320 planted words). A word read the same way in several passes is real; OCR misreads vary. Nothing is written
/// to disk; the image and text only pass through memory. (From freeflow-local's screen-ocr helper.)
enum ScreenOCR {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Text lines from a `data:image/...;base64,` URL, with repeats (see above); empty if it can't be read.
    static func read(dataURL: String) -> [String] {
        var base64 = Substring(dataURL)
        if base64.hasPrefix("data:"), let comma = base64.firstIndex(of: ",") { base64 = base64[base64.index(after: comma)...] }
        guard let data = Data(base64Encoded: String(base64), options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return autoreleasepool { read(image) }
    }

    /// Vision loads its text recognisers on first use, which takes tens of seconds; run one small read to do it early.
    static func warmUp() {
        guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return }
        _ = recognise(image)
    }

    static func read(_ image: CGImage) -> [String] {
        var source = CIImage(cgImage: image)
        if max(image.width, image.height) <= 2048 {
            source = source.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 2.0, "inputAspectRatio": 1.0])
        }
        guard let big = render(source) else { return [] }
        var passes: [CGImage] = []
        for tile in tiles(big, rows: 3, cols: 2) {
            passes.append(tile)
            if let inverted = render(CIImage(cgImage: tile).applyingFilter("CIColorInvert")) { passes.append(inverted) }
        }
        // Sequential: running the passes concurrently was slower (~700 vs ~500 ms on an M4).
        return passes.flatMap(recognise)
    }

    private static func render(_ image: CIImage) -> CGImage? { context.createCGImage(image, from: image.extent) }

    private static func recognise(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false  // keep LoRA, pgvector and names exactly as drawn
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Overlapping tiles (25% overlap) covering the image in `rows` x `cols`.
    private static func tiles(_ image: CGImage, rows: Int, cols: Int) -> [CGImage] {
        let tw = Double(image.width) / (Double(cols) * 0.75 + 0.25)
        let th = Double(image.height) / (Double(rows) * 0.75 + 0.25)
        var out: [CGImage] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(x: Double(c) * tw * 0.75, y: Double(r) * th * 0.75, width: tw, height: th).integral
                if let tile = image.cropping(to: rect) { out.append(tile) }
            }
        }
        return out
    }
}
