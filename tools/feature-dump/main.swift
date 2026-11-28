import Foundation

// Development tool, not part of the app: runs the app's own speech recogniser (Core ML, Neural Engine) on the audio
// files in a JSON-lines manifest ({"path", "text", "set"}) and writes, per clip, what was heard and the per-word
// features the suspect-word labeller uses. Used to train and check the labeller on public or synthetic audio only.
//
// Usage: feature-dump <model directory> <manifest.jsonl> <out prefix>
//   <out prefix>.jsonl : {"id", "set", "heard", "ref", "n_words", "words": [{"w", "frames", "pause", "has"}]}
//   <out prefix>.f32   : float32 little-endian, 1024 per word in order (zeros where "has" is false)

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: feature-dump <model dir> <manifest.jsonl> <out prefix>\n".data(using: .utf8)!)
    exit(2)
}
let recognizer = try SpeechRecognizer(directory: URL(fileURLWithPath: args[1]))
let lines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n")
FileManager.default.createFile(atPath: args[3] + ".jsonl", contents: nil)
FileManager.default.createFile(atPath: args[3] + ".f32", contents: nil)
let meta = FileHandle(forWritingAtPath: args[3] + ".jsonl")!
let vecs = FileHandle(forWritingAtPath: args[3] + ".f32")!
let started = Date()
var failed = 0
for (n, line) in lines.enumerated() {
    guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let path = row["path"] as? String else { continue }
    let heard = try recognizer.transcribe(try SpeechRecognizer.samples(from: URL(fileURLWithPath: path)))
    failed += recognizer.unknownRetriesFailed
    var words: [[String: Any]] = []
    var data = Data()
    for (w, f) in recognizer.lastHeard {
        words.append(["w": w, "frames": f?.frames ?? 0, "pause": f?.pause ?? 0, "has": f != nil])
        var mean = f?.mean ?? [Float](repeating: 0, count: 1024)
        data.append(Data(bytes: &mean, count: mean.count * 4))
    }
    let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let out: [String: Any] = ["id": id, "set": row["set"] ?? "", "heard": heard, "ref": row["text"] ?? "",
                              "n_words": words.count, "words": words]
    meta.write(try JSONSerialization.data(withJSONObject: out) + Data("\n".utf8))
    vecs.write(data)
    if n % 100 == 0 { print(n, Int(Date().timeIntervalSince(started)), "s", heard.prefix(50)) }
}
print("done", lines.count, "clips,", Int(Date().timeIntervalSince(started)), "s; windows still <unk> after retry:", failed)
