import AppKit
import Foundation

/// The separate engine earlier versions needed (freeflow-local: a login agent plus a Python folder of about 3 GB).
/// TellWell runs its engine itself now, so it offers to remove it. Removal stops the login agent and moves the
/// folder to the Trash, so it can be put back.
@MainActor
final class OldEngine: ObservableObject {
    static let shared = OldEngine()

    nonisolated static let agentLabel = "com.freeflow.local"
    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FreeFlowLocal", isDirectory: true)
    }
    nonisolated static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    @Published private(set) var isInstalled = false
    @Published private(set) var sizeBytes: Int64?
    @Published private(set) var error: String?

    /// The original FreeFlow app can use the same engine; removing it would break that app's local setup.
    var freeFlowAppInstalled: Bool {
        ["/Applications/FreeFlow.app", NSHomeDirectory() + "/Applications/FreeFlow.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    func refresh() {
        let fm = FileManager.default
        isInstalled = fm.fileExists(atPath: Self.folder.path) || fm.fileExists(atPath: Self.agentPlist.path)
        guard isInstalled, sizeBytes == nil else { return }
        Task.detached(priority: .utility) {
            let size = Self.allocatedSize(of: Self.folder)
            await MainActor.run { self.sizeBytes = size }
        }
    }

    /// Asks first, then removes. Nothing is removed without the user's confirmation.
    func confirmAndRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove the old engine?"
        var text = "\(AppName.displayName) no longer needs the separate engine installed by earlier versions. "
            + "This stops it and moves its folder (FreeFlowLocal) to the Trash."
        if freeFlowAppInstalled {
            text += "\n\nThe FreeFlow app is also installed and may use this engine; it would stop working with it."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remove()
    }

    private func remove() {
        error = nil
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        stop.arguments = ["bootout", "gui/\(getuid())/\(Self.agentLabel)"]
        stop.standardOutput = FileHandle.nullDevice
        stop.standardError = FileHandle.nullDevice
        try? stop.run()
        stop.waitUntilExit()   // fails harmlessly if the agent isn't loaded

        let fm = FileManager.default
        for url in [Self.agentPlist, Self.folder] where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                self.error = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
            }
        }
        sizeBytes = nil
        refresh()
    }

    nonisolated private static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
