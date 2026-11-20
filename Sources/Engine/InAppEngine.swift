import Foundation

/// TellWell's speech engine, running inside the app: speech recognition on the Neural Engine and cleanup on the GPU.
///
/// It answers the two requests the rest of the app makes, in the same shape as an OpenAI-style server, so the
/// pipeline code is unchanged: `transcribe(fileURL:)` and `chatCompletion(body:)`. It reproduces what the separate
/// engine (freeflow-local) did: the compact cleanup prompt the model was trained on, screen words read from the context
/// screenshot, vocabulary hints, filler stripping and the output guards.
///
/// Privacy: audio, screenshots and text stay in memory and are never logged or stored; the models run on this Mac.
actor InAppEngine {
    static let shared = InAppEngine()

    /// Models are freed after this long without a dictation (they reload in about a second).
    static let idleUnloadSeconds: TimeInterval = 600
    /// At cleanup, wait at most this long for screen reading still in progress (it normally finishes during speech).
    static let screenWordsWait: TimeInterval = 0.5
    /// Screen words older than this (from recording start to cleanup) are ignored.
    static let screenWordsMaxAge: TimeInterval = 300

    private var speech: SpeechRecognizer?
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?
    private var screenWords: [String]?          // this dictation's words, once read
    private var screenGeneration = 0           // invalidates readings from earlier dictations
    private var screenPending = false          // a reading was started for the current dictation
    private var screenTaskStarted = Date.distantPast
    private static var visionWarmedUp = false

    private let workQueue = DispatchQueue(label: "io.github.ayushpatnaikgit.tellwell.engine", qos: .userInitiated)

    enum EngineError: LocalizedError {
        case modelsMissing
        case loadFailed(String)
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .modelsMissing: return "TellWell's models aren't downloaded yet. Open Settings to download them."
            case .loadFailed(let what): return "TellWell couldn't load its \(what) model."
            case .generationFailed: return "Cleanup failed."
            }
        }
    }

    // MARK: - Loading

    /// Loads both models if they aren't loaded (call at app launch and when recording starts).
    func prepare() async throws {
        touch()
        guard ModelStore.modelsPresent else { throw EngineError.modelsMissing }
        if speech == nil {
            speech = try await onWorkQueue {
                do {
                    let recognizer = try SpeechRecognizer(directory: ModelStore.speechDirectory)
                    try recognizer.warmUp()
                    return recognizer
                } catch {
                    throw EngineError.loadFailed("speech")
                }
            }
        }
        if !Self.visionWarmedUp {
            // Vision loads its text recognisers on first use (about 25 s on an M4): do it now, in the background,
            // so the first dictation's screen words are ready in time.
            Self.visionWarmedUp = true
            Task.detached(priority: .utility) { ScreenOCR.warmUp() }
        }
        if !CleanupModel.isLoaded {
            try await onWorkQueue {
                do { try CleanupModel.load(path: ModelStore.cleanupPath.path) } catch { throw EngineError.loadFailed("cleanup") }
            }
        }
    }

    var isLoaded: Bool { speech != nil && CleanupModel.isLoaded }

    /// Frees both models. Called when idle and when the app quits (llama.cpp's GPU backend must be freed before exit).
    func unload() {
        idleTask?.cancel()
        speech = nil
        CleanupModel.unload()
    }

    /// For applicationWillTerminate: frees the cleanup model synchronously, without the actor.
    nonisolated static func unloadForExit() { CleanupModel.unload() }

    private func touch() {
        lastUse = Date()
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleUnloadSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        if Date().timeIntervalSince(lastUse) >= Self.idleUnloadSeconds { unload() }
    }

    /// Model calls block; run them on one serial queue so they never overlap.
    private func onWorkQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Speech

    func transcribe(fileURL: URL) async throws -> String {
        try await prepare()
        guard let speech else { throw EngineError.modelsMissing }
        // Names and terms to favour: the user's vocabulary and this dictation's screen words (read while they spoke).
        var boost: [String] = []
        if UserDefaults.standard.object(forKey: "engine_speech_boost") as? Bool ?? true {
            let vocabulary = TermBoost.vocabulary(UserDefaults.standard.string(forKey: "custom_vocabulary") ?? "")
            boost = TermBoost.terms(vocabulary: vocabulary, screen: await peekScreenWords())
        }
        let terms = boost
        let text = try await onWorkQueue { [speech] in
            try speech.transcribe(try SpeechRecognizer.samples(from: fileURL), boost: terms)
        }
        touch()
        return CleanupText.stripFillers(text)
    }

    // MARK: - Chat (cleanup and context)

    /// An OpenAI-style chat completion: request body in, response body out.
    func chatCompletion(body: Data) async throws -> Data {
        guard var payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawMessages = payload["messages"] as? [[String: Any]] else {
            throw EngineError.generationFailed
        }
        startScreenWords(from: rawMessages)
        try await prepare()

        // Text only: the model can't read images (the screenshot is used for screen words above).
        var messages: [(role: String, content: String)] = rawMessages.map { message in
            let role = message["role"] as? String ?? "user"
            if let text = message["content"] as? String { return (role, text) }
            let parts = message["content"] as? [[String: Any]] ?? []
            return (role, parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined())
        }

        var raw: String?
        var vocabulary: [String] = []
        if messages.count >= 2, messages[0].role == "system", messages.last!.content.contains("RAW_TRANSCRIPTION") {
            if let compact = CleanupText.compactSystemPrompt(messages[0].content) { messages[0].content = compact }
            raw = CleanupText.rawTranscript(messages.last!.content)
            vocabulary = CleanupText.vocabularyTerms(messages[0].content)
            if let raw {
                let screen = await takeScreenWords()
                if !screen.isEmpty || !vocabulary.isEmpty {
                    let known = Set(vocabulary.map { $0.lowercased() })
                    let found = ScreenWords.relevant(vocabulary + screen.filter { !known.contains($0.lowercased()) }, transcript: raw)
                    messages[messages.count - 1].content = CleanupText.addingHints(
                        messages.last!.content, section: ScreenWords.promptSection(found))
                }
            }
        }

        let maxTokens = min((payload["max_tokens"] as? Int) ?? 4096, 4096)
        let chat = messages
        guard var text = try await onWorkQueue({ CleanupModel.complete(chat, maxTokens: maxTokens) }) else {
            throw EngineError.generationFailed
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw {
            text = CleanupText.keepSpokenWords(raw: raw, cleaned: text)
            if CleanupText.expandedTooMuch(raw: raw, cleaned: text).revert { text = raw }
            text = CleanupText.restoreUnsupportedTerms(raw: raw, cleaned: text, terms: vocabulary).0
        }
        touch()
        payload = [
            "id": "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "tellwell",
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Screen words

    private static func screenshot(in messages: [[String: Any]]) -> String? {
        guard let parts = messages.last?["content"] as? [[String: Any]] else { return nil }
        for part in parts where part["type"] as? String == "image_url" {
            let image = part["image_url"]
            let url = (image as? [String: Any])?["url"] as? String ?? image as? String
            if let url, url.hasPrefix("data:image/") { return url }
        }
        return nil
    }

    /// The context request (sent when recording starts) carries the screenshot: read it while the user speaks.
    private func startScreenWords(from messages: [[String: Any]]) {
        guard UserDefaults.standard.object(forKey: "engine_screen_words") as? Bool ?? true,
              let url = Self.screenshot(in: messages) else { return }
        screenGeneration += 1
        let generation = screenGeneration
        screenWords = nil
        screenPending = true
        screenTaskStarted = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let words = ScreenWords.screenWords(ScreenOCR.read(dataURL: url))
            await self?.storeScreenWords(words, generation: generation)
        }
    }

    private func storeScreenWords(_ words: [String], generation: Int) {
        if generation == screenGeneration { screenWords = words }
    }

    /// This dictation's screen words for the speech recogniser, without using them up (cleanup takes them after).
    /// Waits at most `screenWordsWait` for reading still in progress, never longer.
    private func peekScreenWords() async -> [String] {
        guard screenPending, Date().timeIntervalSince(screenTaskStarted) <= Self.screenWordsMaxAge else { return [] }
        let generation = screenGeneration
        let deadline = Date().addingTimeInterval(Self.screenWordsWait)
        while screenWords == nil && Date() < deadline && generation == screenGeneration {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return generation == screenGeneration ? screenWords ?? [] : []
    }

    /// This dictation's screen words: waits at most `screenWordsWait` for reading still in progress, never longer.
    /// Each set is used for one cleanup only.
    private func takeScreenWords() async -> [String] {
        defer { screenWords = nil; screenPending = false; screenGeneration += 1 }
        // Only wait if this dictation's screenshot is being read (none arrives when context capture is off).
        guard screenPending, Date().timeIntervalSince(screenTaskStarted) <= Self.screenWordsMaxAge else { return [] }
        let deadline = Date().addingTimeInterval(Self.screenWordsWait)
        while screenWords == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return screenWords ?? []
    }
}
