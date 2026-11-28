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

    /// Models (about 650 MB) are freed after this long without a dictation. Reloading took 0.6-6 s on an M4 (longer
    /// once macOS has dropped the files from memory), so the first dictation after 10 idle minutes was often slow.
    static let idleUnloadSeconds: TimeInterval = 3600
    /// At cleanup, wait at most this long for screen reading still in progress (it normally finishes during speech).
    static let screenWordsWait: TimeInterval = 0.5
    /// Screen words older than this (from recording start to cleanup) are ignored.
    static let screenWordsMaxAge: TimeInterval = 300

    private var speech: SpeechRecognizer?
    /// The last transcript this engine produced and which of its words the labeller flagged as likely misheard
    /// (TwoPass). Kept in memory only, for the cleanup request about that transcript.
    private var lastTranscript: (text: String, flags: [Bool])?
    /// What two-pass cleanup did to the last cleanup request: "skipped" (used as heard), "gated", or "" (off/n.a.).
    private(set) var lastTwoPassAction = ""
    /// The suspect-word labeller's weights (bundled; nil if missing, which turns flagging off).
    private static let labeller: TwoPass.Labeller? = {
        guard let url = Bundle.main.url(forResource: "two-pass-labeller", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lab = try? JSONDecoder().decode(TwoPass.Labeller.self, from: data), lab.isValid else { return nil }
        return lab
    }()
    /// Two-pass cleanup (router + gate) is on unless turned off with the `engine_two_pass` default.
    private var twoPassOn: Bool { UserDefaults.standard.object(forKey: "engine_two_pass") as? Bool ?? true }
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?
    private var screenWords: [String]?          // this dictation's words, once read
    private var screenGeneration = 0           // invalidates readings from earlier dictations
    private var screenPending = false          // a reading was started for the current dictation
    private var screenTaskStarted = Date.distantPast
    private static var visionWarmedUp = false

    /// The recording as it is written (long dictations are recognised window by window while the user speaks).
    nonisolated let streamed = StreamingAudio(firstWindow: SpeechRecognizer.windowLength, step: SpeechRecognizer.windowStep)
    private var windowCache = WindowCache()
    private var streaming = false

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
        windowCache = WindowCache()
        streamed.reset()
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
        let terms = boostTerms(screen: await peekScreenWords())
        // Windows recognised while the user was speaking (long dictations). Let one in progress finish first.
        let deadline = Date().addingTimeInterval(1)
        while streaming && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        let cache = windowCache.url == fileURL ? windowCache : WindowCache()
        windowCache = WindowCache()
        if streamed.currentURL == fileURL { streamed.reset() }   // not a newer recording's audio
        let (text, heard) = try await onWorkQueue { [speech] in
            let text = try speech.transcribe(try SpeechRecognizer.samples(from: fileURL),
                                             using: terms.isEmpty ? nil : TermBoost(terms: terms),
                                             reuse: { start, samples in cache.lookup(start: start, terms: terms, samples: samples) })
            return (text, speech.lastHeard)
        }
        touch()
        let final = CleanupText.stripFillers(text)
        if let labeller = Self.labeller {
            lastTranscript = (final, TwoPass.flags(for: final, heard: heard.map(\.word), heardFlags: labeller.flags(heard)))
        } else {
            lastTranscript = nil
        }
        return final
    }

    /// The names and terms to favour: vocabulary, the user's own name and this dictation's screen words.
    private func boostTerms(screen: [String]) -> [String] {
        guard UserDefaults.standard.object(forKey: "engine_speech_boost") as? Bool ?? true else { return [] }
        let vocabulary = TermBoost.vocabulary(UserDefaults.standard.string(forKey: "custom_vocabulary") ?? "")
            + TermBoost.ownName(NSFullUserName())
        return TermBoost.terms(vocabulary: vocabulary, screen: screen)
    }

    /// Recognises the recording's full windows while the user is still speaking, so after a long dictation only the
    /// last one is left. Called when the recorder completes a window. Does nothing until this dictation's screen words
    /// are read (the final pass would use a different name list) or if the models aren't loaded.
    func recogniseStreamedWindows() async {
        guard !streaming, let speech else { return }
        streaming = true
        defer { streaming = false }
        while true {
            let (url, samples) = streamed.snapshot()
            guard let url else { return }
            if windowCache.url != url { windowCache = WindowCache(url: url) }
            guard let start = windowCache.nextStart(available: samples.count, window: SpeechRecognizer.windowLength,
                                                    step: SpeechRecognizer.windowStep),
                  let screen = screenWordsIfRead() else { return }
            let terms = boostTerms(screen: screen)
            let decoded = try? await onWorkQueue { [speech] in
                try speech.fullWindow(samples, start: start, using: terms.isEmpty ? nil : TermBoost(terms: terms))
            }
            guard let tokens = decoded ?? nil, windowCache.url == url else { return }
            windowCache.store(start: start, terms: terms,
                              samples: samples[start..<(start + SpeechRecognizer.windowLength)], tokens: tokens)
        }
    }

    /// This dictation's screen words if reading has finished ([] if none are being read), nil while still reading.
    private func screenWordsIfRead() -> [String]? {
        guard screenPending, Date().timeIntervalSince(screenTaskStarted) <= Self.screenWordsMaxAge else { return [] }
        return screenWords
    }

    // MARK: - Chat (cleanup and context)

    /// An OpenAI-style chat completion: request body in, response body out.
    func chatCompletion(body: Data) async throws -> Data {
        guard let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
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

        // The context request: describing the activity took the cleanup model 0.6-2.5 s (it wasn't trained for it and
        // can't see the screenshot), held up the dictation behind it and pushed the cleanup prompt out of its cache.
        // The app and window it was given say the same thing, at once. Screen words were started above.
        if !messages.contains(where: { $0.content.contains("RAW_TRANSCRIPTION") }),
           let summary = CleanupText.contextSummary(messages.last?.content ?? "") {
            touch()
            return try Self.response(summary)
        }

        var raw: String?
        var vocabulary: [String] = []
        var defaultPrompt = false                  // the app's own cleanup prompt, with no language instructions
        var hintTerms: [String] = []               // listed terms and this dictation's screen words
        if messages.count >= 2, messages[0].role == "system", messages.last!.content.contains("RAW_TRANSCRIPTION") {
            if let compact = CleanupText.compactSystemPrompt(messages[0].content) {
                messages[0].content = compact
                defaultPrompt = !compact.contains("\n\nIMPORTANT: ")
            }
            raw = CleanupText.rawTranscript(messages.last!.content)
            vocabulary = CleanupText.vocabularyTerms(messages[0].content)
            if let raw {
                let screen = await takeScreenWords()
                hintTerms = vocabulary + screen
                if !screen.isEmpty || !vocabulary.isEmpty {
                    let known = Set(vocabulary.map { $0.lowercased() })
                    let found = ScreenWords.relevant(vocabulary + screen.filter { !known.contains($0.lowercased()) }, transcript: raw)
                    messages[messages.count - 1].content = CleanupText.addingHints(
                        messages.last!.content, section: ScreenWords.promptSection(found))
                }
            }
        }

        // Two-pass cleanup: the flags apply only to the transcript they were made for.
        var flags: [Bool]?
        lastTwoPassAction = ""
        if let raw, twoPassOn, defaultPrompt {
            let words = raw.split(separator: " ").count
            if let last = lastTranscript, last.text == raw, last.flags.count == words { flags = last.flags }
            // Nothing in the transcript calls for cleanup: use it as heard.
            if let flags, TwoPass.canSkipCleanup(heard: raw, flags: flags, terms: hintTerms) {
                touch()
                lastTwoPassAction = "skipped"
                return try Self.response(raw)
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
            // Undo changes the gate doesn't allow (no flags if the transcript isn't the one just recognised).
            if twoPassOn, defaultPrompt, !text.isEmpty {
                let f = flags ?? [Bool](repeating: false, count: raw.split(separator: " ").count)
                text = TwoPass.gate(heard: raw, cleaned: text, flags: f, terms: hintTerms)
                lastTwoPassAction = "gated"
            }
        }
        touch()
        return try Self.response(text)
    }

    /// An OpenAI-style chat completion response carrying `text`.
    private static func response(_ text: String) throws -> Data {
        let payload: [String: Any] = [
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
