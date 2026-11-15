import AppKit
import Foundation
import SwiftUI

/// The speech engine runs inside TellWell (see Engine/InAppEngine.swift). The pipeline still builds OpenAI-style
/// requests for this local address; InAppEngineTransport answers them in the app, with no network involved.
enum LocalEngine {
    static let baseURL = "http://127.0.0.1:8081/v1"
    /// The engine ignores the key, but the provider settings need a non-empty one.
    static let apiKey = "local"

    /// Whether a URL points at the in-app engine.
    static func isLocal(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://127.0.0.1:8081") || trimmed.hasPrefix("http://localhost:8081")
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
