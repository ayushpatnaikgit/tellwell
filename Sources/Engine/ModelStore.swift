import CryptoKit
import Foundation

/// The engine's model files, downloaded once (about 830 MB) and kept in ~/Library/Application Support/TellWell/Models.
///
/// Files come from TellWell's own mirror (github.com/ayushpatnaikgit/tellwell-models, release v1), with the pinned
/// Hugging Face originals as a fallback. Every file is kept only if its SHA-256 matches; nothing else is ever trusted.
/// Nothing is uploaded.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum State: Equatable {
        case missing
        case downloading(fraction: Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    private struct RemoteFile {
        let urls: [URL]          // tried in order
        let size: Int64
        let sha256: String
    }

    nonisolated private static let mirror = "https://github.com/ayushpatnaikgit/tellwell-models/releases/download/v1/"
    nonisolated private static let speechHF = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/ee09c569f73759e6d44c9bd16766f477b2b36d39/"
    nonisolated private static let cleanupHF = "https://huggingface.co/ayushpatnaik/S1-mini-FreeFlow-cleanup-GGUF/resolve/6665acc599d42d7adc2d55c577119e56ee22810d/"

    /// The speech model as one zip from the mirror.
    nonisolated private static let speechZip = RemoteFile(
        urls: [URL(string: mirror + "parakeet-tdt-0.6b-v2-coreml.zip")!],
        size: 450_268_451, sha256: "ae3ea934db9350bf137a4768bdca27931e6ef9352df14b4c6f275aa9158df503")

    /// The same files individually from Hugging Face, if the mirror can't be reached.
    nonisolated private static let speechFiles: [(path: String, size: Int64, sha256: String)] = [
        ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8"),
        ("Preprocessor.mlmodelc/coremldata.bin", 494, "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6"),
        ("Preprocessor.mlmodelc/metadata.json", 2974, "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb"),
        ("Preprocessor.mlmodelc/model.mil", 27166, "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e"),
        ("Preprocessor.mlmodelc/weights/weight.bin", 298880, "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc"),
        ("Encoder.mlmodelc/analytics/coremldata.bin", 243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        ("Encoder.mlmodelc/coremldata.bin", 485, "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030"),
        ("Encoder.mlmodelc/metadata.json", 2926, "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63"),
        ("Encoder.mlmodelc/model.mil", 959769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        ("Encoder.mlmodelc/weights/weight.bin", 445187200, "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"),
        ("Decoder.mlmodelc/analytics/coremldata.bin", 243, "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05"),
        ("Decoder.mlmodelc/coremldata.bin", 554, "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8"),
        ("Decoder.mlmodelc/metadata.json", 3427, "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2"),
        ("Decoder.mlmodelc/model.mil", 13106, "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579"),
        ("Decoder.mlmodelc/weights/weight.bin", 14429952, "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba"),
        ("JointDecision.mlmodelc/analytics/coremldata.bin", 243, "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7"),
        ("JointDecision.mlmodelc/coremldata.bin", 534, "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11"),
        ("JointDecision.mlmodelc/metadata.json", 2936, "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c"),
        ("JointDecision.mlmodelc/model.mil", 9722, "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0"),
        ("JointDecision.mlmodelc/weights/weight.bin", 3453388, "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d"),
        ("parakeet_vocab.json", 18762, "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97"),
    ]

    nonisolated private static let cleanupFile = RemoteFile(
        urls: [URL(string: mirror + "s1-mini-freeflow-cleanup-q4_0.gguf")!,
               URL(string: cleanupHF + "s1-mini-freeflow-cleanup-q4_0.gguf")!],
        size: 381_565_696, sha256: "ff7dfbc19d7220ac7e1f7cd88bc95da3db7e7e7893a35ea552895727605abddc")

    nonisolated static let totalBytes: Int64 = speechZip.size + cleanupFile.size
    /// The Core ML speech models need macOS 14 (they are spec version 8); the app itself builds for 13.
    nonisolated static var systemSupported: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) }

    nonisolated static var directory: URL {
        // TELLWELL_MODELS_DIR: for development and tests only (e.g. keep test downloads on another disk).
        if let custom = ProcessInfo.processInfo.environment["TELLWELL_MODELS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TellWell/Models", isDirectory: true)
    }
    nonisolated static var speechDirectory: URL { directory.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true) }
    nonisolated static var cleanupPath: URL { directory.appendingPathComponent("s1-mini-freeflow-cleanup-q4_0.gguf") }
    /// Written after the speech files are verified, so a half-finished install is never used.
    nonisolated private static var speechMarker: URL { speechDirectory.appendingPathComponent(".verified-v1") }

    nonisolated static var modelsPresent: Bool {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: cleanupPath.path)[.size] as? NSNumber)?.int64Value
        return fm.fileExists(atPath: speechMarker.path) && size == cleanupFile.size
    }

    private var task: Task<Void, Never>?

    private init() {
        state = Self.modelsPresent ? .ready : .missing
    }

    func refresh() {
        if task == nil { state = Self.modelsPresent ? .ready : .missing }
    }

    /// Downloads whatever is missing. Safe to call repeatedly.
    func download() {
        guard task == nil, !Self.modelsPresent else { refresh(); return }
        state = .downloading(fraction: 0)
        task = Task {
            do {
                try await Self.performDownload { done in
                    Task { @MainActor in
                        if case .downloading = ModelStore.shared.state {
                            ModelStore.shared.state = .downloading(fraction: min(1, Double(done) / Double(Self.totalBytes)))
                        }
                    }
                }
                state = .ready
            } catch {
                state = .failed((error as? DownloadError)?.message ?? "The download didn't finish. Check your connection and try again.")
            }
            task = nil
        }
    }

    /// Runs off the main thread (nonisolated async).
    nonisolated private static func performDownload(report: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await installSpeech(base: 0, report: report)
        if !FileManager.default.fileExists(atPath: cleanupPath.path) {
            try await fetch(cleanupFile, to: cleanupPath, base: speechZip.size, report: report)
        }
    }

    private struct DownloadError: Error, Sendable { let message: String }

    /// Speech model: the mirror's zip (checked, unpacked with ditto), else the individual Hugging Face files.
    nonisolated private static func installSpeech(base: Int64, report: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: speechMarker.path) { return }
        let staging = directory.appendingPathComponent(".speech-staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            let zip = staging.appendingPathComponent("speech.zip")
            try await fetch(speechZip, to: zip, base: base, report: report)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, staging.appendingPathComponent("files").path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw DownloadError(message: "Couldn't unpack the speech model.") }
            try? fm.removeItem(at: zip)
        } catch {
            // Mirror unavailable: the same files from the pinned Hugging Face revision, each checked.
            var done = base
            for file in speechFiles {
                let dest = staging.appendingPathComponent("files").appendingPathComponent(file.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let remote = RemoteFile(urls: [URL(string: speechHF + file.path)!], size: file.size, sha256: file.sha256)
                try await fetch(remote, to: dest, base: done, report: report)
                done += file.size
            }
        }
        // Every unpacked file must match the pinned size (the zip itself was checked by SHA-256).
        for file in speechFiles {
            let path = staging.appendingPathComponent("files").appendingPathComponent(file.path).path
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            guard size == file.size else { throw DownloadError(message: "The speech model was incomplete.") }
        }
        try? fm.removeItem(at: speechDirectory)
        try fm.moveItem(at: staging.appendingPathComponent("files"), to: speechDirectory)
        fm.createFile(atPath: speechMarker.path, contents: Data("parakeet-tdt-0.6b-v2-coreml ee09c569\n".utf8))
    }

    /// Downloads `file` (trying each URL) to `dest`, keeping it only if size and SHA-256 match.
    nonisolated private static func fetch(_ file: RemoteFile, to dest: URL, base: Int64,
                                          report: @escaping @Sendable (Int64) -> Void) async throws {
        var lastError: Error = DownloadError(message: "The download didn't finish. Check your connection and try again.")
        for url in file.urls {
            do {
                let temp = try await download(url, expected: file.size) { report(base + $0) }
                defer { try? FileManager.default.removeItem(at: temp) }
                guard try sha256(of: temp) == file.sha256 else {
                    throw DownloadError(message: "A model file didn't match its checksum, so it wasn't used.")
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    nonisolated private static func download(_ url: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError(message: "The model server didn't respond.") }
        let temp = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(written)
                guard written <= expected else { throw DownloadError(message: "A model file was larger than expected.") }
            }
        }
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        progress(written)
        return temp
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
