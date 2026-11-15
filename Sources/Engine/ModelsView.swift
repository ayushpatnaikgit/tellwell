import Foundation
import SwiftUI

/// Model status and download, shared by setup and Settings.
struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    /// Setup starts the download by itself; Settings waits for a click.
    var startAutomatically = false

    private static let totalMB = Int(ModelStore.totalBytes / 1_000_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ModelStore.systemSupported {
                Label("\(AppName.displayName)'s speech models need macOS 14 (Sonoma) or later.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                content
            }
            Text("Your voice and text never leave this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            store.refresh()
            oldEngine.refresh()
            if startAutomatically && store.state == .missing && ModelStore.systemSupported { store.download() }
        }
    }

    @ViewBuilder private var content: some View {
            switch store.state {
            case .ready:
                Label("Ready on this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                row("waveform", "Speech recognition", "NVIDIA Parakeet v2 (English), Neural Engine")
                row("text.badge.checkmark", "Cleanup", "S1-mini, GPU")
                if oldEngine.isInstalled { oldEngineCard }
            case .missing:
                Text("\(AppName.displayName) runs speech recognition and cleanup on your Mac. It needs to download its models once (about \(Self.totalMB) MB).")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download models") { store.download() }
                    .buttonStyle(.borderedProminent)
            case .downloading(let fraction):
                Text("Downloading models (about \(Self.totalMB) MB, once)…")
                ProgressView(value: fraction)
                Text("\(Int(fraction * Double(Self.totalMB))) of \(Self.totalMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { store.download() }
            }
    }

    @ObservedObject private var oldEngine = OldEngine.shared

    private var oldEngineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The separate engine from earlier versions is still installed"
                 + (oldEngine.sizeBytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? "")
                 + ". \(AppName.displayName) doesn't need it any more.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Remove old engine…") { oldEngine.confirmAndRemove() }
            if let error = oldEngine.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(TellWellBrand.accent)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Sends the app's OpenAI-style requests to the in-app engine instead of the network.
enum InAppEngineTransport {
    /// The engine's answer, or nil if the request isn't one the engine serves.
    static func respond(to request: URLRequest) async throws -> (Data, URLResponse)? {
        guard let url = request.url, LocalEngine.isLocal(url.absoluteString) else { return nil }
        let data: Data
        if url.path.hasSuffix("/chat/completions") {
            data = try await InAppEngine.shared.chatCompletion(body: request.httpBody ?? Data())
        } else if url.path.hasSuffix("/models") {
            data = Data(#"{"object":"list","data":[{"id":"tellwell","object":"model"}]}"#.utf8)
        } else {
            return nil
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}
