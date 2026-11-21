import Foundation

/// Recognising long dictations while the user speaks: the streamed audio and the cache of windows decoded from it.
/// Synthetic samples and tokens only.
enum StreamingAudioTests {
    static func run() {
        windowBoundaries()
        chunkedEqualsWhole()
        cacheMatchesExactly()
    }

    private static func windowBoundaries() {
        // Windows of 15 end at 15, 27, 39 (step 12).
        TestSupport.expectEqual(StreamingAudio.windowsCompleted(before: 0, after: 14, firstWindow: 15, step: 12), 0)
        TestSupport.expectEqual(StreamingAudio.windowsCompleted(before: 14, after: 15, firstWindow: 15, step: 12), 1)
        TestSupport.expectEqual(StreamingAudio.windowsCompleted(before: 15, after: 26, firstWindow: 15, step: 12), 0)
        TestSupport.expectEqual(StreamingAudio.windowsCompleted(before: 10, after: 40, firstWindow: 15, step: 12), 3)
    }

    private static func chunkedEqualsWhole() {
        let pcm: [Int16] = (0..<100).map { Int16(truncatingIfNeeded: $0 * 997 - 30_000) }
        let url = URL(fileURLWithPath: "/tmp/synthetic-recording.wav")
        let audio = StreamingAudio(firstWindow: 40, step: 30)
        var signals = 0
        for chunk in stride(from: 0, to: pcm.count, by: 7) {
            let part = Array(pcm[chunk..<min(chunk + 7, pcm.count)])
            if part.withUnsafeBufferPointer({ audio.append(url: url, $0) }) { signals += 1 }
        }
        let (got, samples) = audio.snapshot()
        TestSupport.expectEqual(got, url)
        TestSupport.expectEqual(samples, pcm.map { Float($0) / 32768 })
        TestSupport.expectEqual(signals, 3)                     // windows ending at 40, 70 and 100
        // A new recording starts over.
        let other = URL(fileURLWithPath: "/tmp/synthetic-recording-2.wav")
        [Int16(1)].withUnsafeBufferPointer { _ = audio.append(url: other, $0) }
        TestSupport.expectEqual(audio.snapshot().samples.count, 1)
    }

    private static func cacheMatchesExactly() {
        let samples: [Float] = (0..<50).map { Float($0) / 100 }
        let tokens = [WindowStitch.Token(id: 3, time: 0.1), WindowStitch.Token(id: 7, time: 0.4)]
        var cache = WindowCache(url: URL(fileURLWithPath: "/tmp/synthetic-recording.wav"))
        TestSupport.expectEqual(cache.nextStart(available: 30, window: 20, step: 15), 0)
        cache.store(start: 0, terms: ["Kavya"], samples: samples[0..<20], tokens: tokens)
        TestSupport.expectEqual(cache.nextStart(available: 30, window: 20, step: 15), nil)   // 15 + 20 > 30
        TestSupport.expectEqual(cache.nextStart(available: 35, window: 20, step: 15), 15)
        TestSupport.expect(cache.lookup(start: 0, terms: ["Kavya"], samples: samples[0..<20])?.count == 2, "same window is reused")
        var changed = samples
        changed[5] += 0.001
        TestSupport.expect(cache.lookup(start: 0, terms: ["Kavya"], samples: changed[0..<20]) == nil, "different audio is not reused")
        TestSupport.expect(cache.lookup(start: 0, terms: ["Kavya", "Mrinal"], samples: samples[0..<20]) == nil,
                           "a different name list is not reused")
        TestSupport.expect(cache.lookup(start: 0, terms: ["Kavya"], samples: samples[0..<19]) == nil, "a shorter window is not reused")
        TestSupport.expect(cache.lookup(start: 15, terms: ["Kavya"], samples: samples[15..<35]) == nil, "an undecoded window is not reused")
    }
}
