import Foundation

/// When to offer an engine (freeflow-local) update. Kept free of UI and networking so it can be tested.
enum EngineUpdatePolicy {
    /// - Parameters:
    ///   - installed: the version the running engine reports at /health ("v0.3.6"). nil means the engine is from
    ///     before engines reported their version (0.3.5 or earlier), so any proper release is newer.
    ///   - latest: the newest freeflow-local release tag on GitHub.
    static func updateAvailable(installed: String?, latest: String) -> Bool {
        guard let latestVersion = SemanticVersion(latest), latestVersion.prerelease.isEmpty else { return false }
        guard let installed, let installedVersion = SemanticVersion(installed) else { return true }
        return installedVersion < latestVersion
    }
}
