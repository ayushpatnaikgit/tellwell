import AppKit
import Foundation
import SwiftUI

/// The on-device engine (freeflow-local) that TellWell uses by default: speech recognition and cleanup on this Mac,
/// served at http://127.0.0.1:8081 with an OpenAI-compatible API.
enum LocalEngine {
    static let baseURL = "http://127.0.0.1:8081/v1"
    /// The engine ignores the key, but the provider settings need a non-empty one.
    static let apiKey = "local"
    static let installCommand = "curl -fsSL https://ayushpatnaikgit.github.io/tellwell/install.sh | sh"
    private static let healthURL = URL(string: "http://127.0.0.1:8081/health")!

    struct Status: Equatable {
        var onNeuralEngine: Bool
        var cleanupModel: String
        var boosting: Bool
        var learning: Bool
        var learnedTerms: Int
        var screenWords: Bool

        var speechDescription: String { onNeuralEngine ? "Neural Engine" : "GPU" }

        /// "ayushpatnaik/S1-mini-FreeFlow-cleanup-MLX-6bit" or a local folder path -> "S1-mini-FreeFlow-cleanup-MLX-6bit"
        var cleanupDescription: String {
            let name = cleanupModel.split(separator: "/").last.map(String.init) ?? cleanupModel
            return name.isEmpty ? "unknown" : name
        }
    }

    /// The engine's status, or nil if it isn't running. Only talks to this Mac (127.0.0.1).
    static func probe(timeout: TimeInterval = 2) async -> Status? {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            return nil
        }
        return Status(
            onNeuralEngine: (json["asr_backend"] as? String) == "ane",
            cleanupModel: json["llm_model"] as? String ?? "",
            boosting: json["asr_boost"] as? Bool ?? false,
            learning: json["vocab_learn"] as? Bool ?? false,
            learnedTerms: json["learned_terms"] as? Int ?? 0,
            screenWords: json["screen_words"] as? Bool ?? false
        )
    }

    /// Whether a saved base URL points at the local engine.
    static func isLocal(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://127.0.0.1:8081") || trimmed.hasPrefix("http://localhost:8081")
    }

    static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }
}

/// TellWell's accent: teal (#0B8A87 in light mode, #2DD4BF in dark mode).
enum TellWellBrand {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x2D / 255, green: 0xD4 / 255, blue: 0xBF / 255, alpha: 1)
            : NSColor(red: 0x0B / 255, green: 0x8A / 255, blue: 0x87 / 255, alpha: 1)
    })
}

/// "Install the engine" box: the one-line command with a Copy button.
struct EngineInstallCommandView: View {
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(LocalEngine.installCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                LocalEngine.copyInstallCommand()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }
}
