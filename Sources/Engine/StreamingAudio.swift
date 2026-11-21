import Foundation

/// The recording's audio as it is written, so long dictations can be recognised while the user is still speaking.
/// The recorder appends the same 16 kHz samples it writes to the recording file; held in memory only, for the
/// current recording, and never logged or stored.
final class StreamingAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var samples: [Float] = []
    private let firstWindow: Int
    private let step: Int

    /// `firstWindow` and `step` (in samples) say when a new full recognition window becomes available.
    init(firstWindow: Int, step: Int) {
        self.firstWindow = firstWindow
        self.step = step
    }

    /// Appends a buffer of the recording at `url` (a new URL starts a new recording). Returns true when this buffer
    /// completed a recognition window, so the caller can start on it. Called on the capture queue: copies and returns.
    @discardableResult
    func append(url: URL, _ pcm: UnsafeBufferPointer<Int16>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if url != self.url {
            self.url = url
            samples = []
            samples.reserveCapacity(60 * 16_000)
        }
        let before = samples.count
        // The same conversion AVAudioConverter applies when the file is read back as Float32.
        samples.append(contentsOf: pcm.lazy.map { Float($0) / 32768 })
        return Self.windowsCompleted(before: before, after: samples.count, firstWindow: firstWindow, step: step) > 0
    }

    /// The recording's URL and samples so far (a copy).
    func snapshot() -> (url: URL?, samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (url, samples)
    }

    var currentURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        url = nil
        samples = []
    }

    /// How many window ends (at firstWindow, firstWindow + step, ...) lie in (before, after].
    static func windowsCompleted(before: Int, after: Int, firstWindow: Int, step: Int) -> Int {
        func ended(_ n: Int) -> Int { n < firstWindow ? 0 : (n - firstWindow) / step + 1 }
        return ended(after) - ended(before)
    }
}

/// Windows recognised while the user was speaking, kept for the final recognition of the same recording. A window is
/// reused only if its start, the name list and every sample match, so the text is the same as recognising afterwards.
struct WindowCache {
    struct Entry {
        let terms: [String]
        let samples: [Float]
        let tokens: [WindowStitch.Token]
    }

    private(set) var url: URL?
    private var entries: [Int: Entry] = [:]

    init(url: URL? = nil) { self.url = url }

    var count: Int { entries.count }

    /// The next window start to recognise (in order), if `available` samples cover it, else nil.
    func nextStart(available: Int, window: Int, step: Int) -> Int? {
        let start = entries.count * step
        return start + window <= available ? start : nil
    }

    mutating func store(start: Int, terms: [String], samples: ArraySlice<Float>, tokens: [WindowStitch.Token]) {
        entries[start] = Entry(terms: terms, samples: Array(samples), tokens: tokens)
    }

    func lookup(start: Int, terms: [String], samples: ArraySlice<Float>) -> [WindowStitch.Token]? {
        guard let entry = entries[start], entry.terms == terms, entry.samples.elementsEqual(samples) else { return nil }
        return entry.tokens
    }
}
