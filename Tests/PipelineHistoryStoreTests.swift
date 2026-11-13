import Foundation

enum PipelineHistoryStoreTests {
    static func run() {
        let store = PipelineHistoryStore(inMemory: true)
        let item = PipelineHistoryItem(
            timestamp: Date(),
            rawTranscript: "synthetic raw words",
            postProcessedTranscript: "Synthetic raw words.",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "none",
            postProcessingStatus: "ok",
            debugStatus: "",
            customVocabulary: ""
        )
        do {
            _ = try store.append(item, maxCount: 20)
        } catch {
            TestSupport.expect(false, "In-memory history must accept entries: \(error)")
        }
        TestSupport.expectEqual(store.loadAllHistory().map(\.id), [item.id])

        // History is per session: a new store (the next launch) starts empty because nothing was written to disk.
        TestSupport.expect(PipelineHistoryStore(inMemory: true).loadAllHistory().isEmpty,
                           "In-memory history must not persist between stores")
    }
}
