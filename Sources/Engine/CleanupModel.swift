import Foundation

/// The cleanup model (S1-mini, GGUF) through llama.cpp on the GPU, via the shared C++ library (tw_cleanup.cpp).
/// Calls block, so run them off the main thread. The library keeps the previous prompt cached and decodes with
/// copy-ahead drafts (same text as greedy decoding, faster).
enum CleanupModel {
    private static let draftTokens: Int32 = 4

    /// Loads the model onto the GPU. Throws if the file can't be loaded.
    static func load(path: String) throws {
        if tw_cleanup_is_loaded() != 0 { return }
        guard tw_cleanup_load(path, 99, 4, 4096) == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    static var isLoaded: Bool { tw_cleanup_is_loaded() != 0 }

    /// Frees the model (and the GPU memory). Must run before the app exits.
    static func unload() { tw_cleanup_unload() }

    /// Renders a chat with the model's template (Qwen3, thinking off), as mlx_lm's server did.
    static func render(_ messages: [(role: String, content: String)]) -> String {
        var prompt = ""
        for m in messages { prompt += "<|im_start|>\(m.role)\n\(m.content)<|im_end|>\n" }
        return prompt + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Greedy completion of a chat. Returns nil if generation failed.
    static func complete(_ messages: [(role: String, content: String)], maxTokens: Int) -> String? {
        guard let pointer = tw_cleanup_complete(render(messages), Int32(maxTokens), draftTokens) else { return nil }
        defer { tw_cleanup_free(pointer) }
        return String(cString: pointer)
    }
}
