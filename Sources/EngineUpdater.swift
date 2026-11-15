import AppKit
import Foundation

/// Offers updates for the on-device engine (freeflow-local), the way UpdateManager does for TellWell itself.
///
/// It compares the version the running engine reports at http://127.0.0.1:8081/health with the newest
/// freeflow-local release on GitHub. If a newer one exists it asks first; only when the user clicks Update does it
/// run the engine's installer (freeflow-local's get.sh) with --no-freeflow --no-configure: it installs the engine
/// release only if it matches its published SHA-256, keeps models, settings and learned words, and restarts the
/// engine, without installing or replacing any app (TellWell's own install.sh would reinstall TellWell) and without
/// reconfiguring apps (which quits and reopens them). `freeflowctl update` does the same from Terminal, but engines
/// before 0.3.6 don't have it, so the app runs the installer itself. Its output stays in memory and is shown only if the update fails; it holds no dictation
/// content.
@MainActor
final class EngineUpdater {
    static let shared = EngineUpdater()

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/ayushpatnaikgit/freeflow-local/releases/latest")!
    private var isUpdating = false

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "engineUpdateSkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "engineUpdateSkippedVersion") }
    }

    private static var engineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FreeFlowLocal", isDirectory: true)
    }

    private static var freeflowctl: URL { engineDirectory.appendingPathComponent("freeflowctl") }

    func check(userInitiated: Bool) async {
        guard !isUpdating,
              FileManager.default.isExecutableFile(atPath: Self.freeflowctl.path),
              let status = await LocalEngine.probe(),
              let latest = await latestReleaseTag(),
              EngineUpdatePolicy.updateAvailable(installed: status.version, latest: latest) else { return }
        if !userInitiated && skippedVersion == latest { return }

        let alert = NSAlert()
        alert.messageText = "Speech engine update available"
        alert.informativeText = """
        TellWell's on-device speech engine \(latest) is available (you have \(status.version ?? "an earlier version")).

        Updating downloads it from GitHub, checks it against its published SHA-256, and restarts the engine. Your \
        models, settings and learned words are kept. It usually takes under a minute.
        """
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if !userInitiated {
            alert.addButton(withTitle: "Skip This Version")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await runUpdate(to: latest)
        case .alertThirdButtonReturn:
            skippedVersion = latest
        default:
            break
        }
    }

    private func latestReleaseTag() async -> String? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["tag_name"] as? String
    }

    private func runUpdate(to version: String) async {
        isUpdating = true
        defer { isUpdating = false }
        let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", EngineUpdater.updateScript]
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            // The installer needs uv (installed to ~/.local/bin) and the usual tool locations; apps start with a
            // minimal PATH.
            environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }.value

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        if result.0 == 0 {
            alert.messageText = "Speech engine updated"
            alert.informativeText = "The engine is now \(version). It restarts on its own; your next dictation may take a few seconds longer while it loads."
        } else {
            alert.messageText = "Speech engine update failed"
            let tail = result.1.split(separator: "\n").suffix(8).joined(separator: "\n")
            alert.informativeText = "If the download or the checksum check failed, nothing was changed. You can also update from Terminal with the install command on TellWell's website.\n\n\(tail)"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Download the engine's installer to a temporary file and run it for the engine only.
    nonisolated private static let updateScript = """
    tmp=$(mktemp "${TMPDIR:-/tmp}/tellwell-engine-update.XXXXXX") || exit 1
    curl -fsSL "\(LocalEngine.engineInstallerURL)" -o "$tmp" || { rm -f "$tmp"; echo "Could not download the installer"; exit 1; }
    sh "$tmp" --no-freeflow --no-configure
    status=$?
    rm -f "$tmp"
    exit $status
    """
}
