import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - Shared Helpers

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private let iso8601DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.visibleCases) { tab in
                    Button {
                        appState.selectedSettingsTab = tab
                    } label: {
                        SettingsSidebarRow(title: tab.title, icon: tab.icon)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.selectedSettingsTab == tab
                                          ? Color.accentColor.opacity(0.15)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch appState.selectedSettingsTab {
                case .general, .none:
                    GeneralSettingsView()
                case .debug:
                    DebugSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(TellWellBrand.accent)
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 16, height: 16, alignment: .center)
                .foregroundStyle(.primary)

            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
}

// MARK: - Debug Settings

struct DebugSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Debug")
                    .font(.largeTitle.bold())

                SettingsCard("Overlay", icon: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Show the recording overlay with simulated audio levels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(appState.isDebugOverlayActive ? "Stop Debug Overlay" : "Debug Overlay") {
                            appState.toggleDebugOverlay()
                        }
                    }
                }

                SettingsCard("Update Overlay", icon: "arrow.down.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Display the update available overlay after dictation finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Show after dictation", isOn: $appState.debugShowsUpdateReminderAfterDictation)

                        Button("Show Update Overlay Now") {
                            appState.showDebugUpdateAvailableOverlay()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true
    @AppStorage("overlay_display_id") private var overlayDisplayID = 0
    @AppStorage("use_compact_overlay") private var useCompactOverlay = true
    @AppStorage(RecordingTimerPreference.storageKey) private var showRecordingTimer = RecordingTimerPreference.defaultEnabled
    @State private var screensVersion = 0
    @State private var customVocabularyInput: String = ""
    @FocusState private var customVocabularyFocused: Bool
    @State private var micPermissionGranted = false
    @State private var showMutedHint = false
    @State private var copiedBuildInfo = false
    @State private var copiedBuildInfoResetWorkItem: DispatchWorkItem?
    @State private var engineStatus: LocalEngine.Status?
    @State private var engineChecked = false
    @ObservedObject private var updateManager = UpdateManager.shared

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "\(AppName.displayName)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "FreeFlowBuildTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var appArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var buildDiagnosticsText: String {
        "\(appDisplayName) \(appVersion) (\(appBuildNumber))\nmacOS \(macOSVersion) (\(appArchitecture))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App branding header
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text(AppName.displayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))

                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Built on FreeFlow by Zach Latta")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 4)

                SettingsCard("Speech Engine", icon: "cpu") {
                    engineSection
                }

                SettingsCard("App", icon: "power") {
                    startupSection
                }
                SettingsCard("Updates", icon: "arrow.triangle.2.circlepath") {
                    updatesSection
                }
                SettingsCard("Dictation Shortcuts", icon: "keyboard.fill") {
                    hotkeySection
                }
                SettingsCard("Audio During Dictation", icon: "speaker.slash.fill") {
                    dictationAudioSection
                }
                SettingsCard("Recording Overlay", icon: "rectangle.dashed") {
                    overlaySection
                }
                SettingsCard("Cleanup", icon: "sparkles") {
                    cleanupSection
                }
                SettingsCard("Text insertion", icon: "text.cursor") {
                    textInsertionSection
                }
                SettingsCard("Clipboard", icon: "doc.on.clipboard") {
                    clipboardSection
                }
                SettingsCard("Microphone", icon: "mic.fill") {
                    microphoneSection
                }
                SettingsCard("Sound Volume", icon: "speaker.wave.2.fill") {
                    soundVolumeSection
                }
                SettingsCard("Custom Vocabulary", icon: "text.book.closed.fill") {
                    vocabularySection
                }
                SettingsCard("Permissions", icon: "lock.shield.fill") {
                    permissionsSection
                }
                SettingsCard("Build", icon: "info.circle.fill") {
                    buildInfoSection
                }
            }
            .padding(24)
        }
        .onAppear {
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
            appState.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            commitCustomVocabulary()
        }
    }

    // MARK: Startup

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Launch \(AppName.displayName) at login", isOn: $appState.launchAtLogin)
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)

            if SMAppService.mainApp.status == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Login item requires approval in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updateManager.autoCheckEnabled },
                set: { updateManager.autoCheckEnabled = $0 }
            ))

            HStack(spacing: 10) {
                Button {
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                } label: {
                    if updateManager.isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                        }
                    } else {
                        Text("Check for Updates Now")
                    }
                }
                .disabled(updateManager.isChecking || updateManager.updateStatus != .idle)

                if let lastCheck = updateManager.lastCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if updateManager.updateAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    switch updateManager.updateStatus {
                    case .downloading:
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Downloading update...")
                                    .font(.caption.weight(.semibold))
                                ProgressView(value: updateManager.downloadProgress ?? 0)
                                    .progressViewStyle(.linear)
                                if let progress = updateManager.downloadProgress {
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Cancel") {
                                updateManager.cancelDownload()
                            }
                            .font(.caption)
                        }

                    case .installing:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing update...")
                                .font(.caption.weight(.semibold))
                        }

                    case .readyToRelaunch:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Relaunching...")
                                .font(.caption.weight(.semibold))
                        }

                    case .error(let message):
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Retry") {
                                updateManager.updateStatus = .idle
                                if let release = updateManager.latestRelease {
                                    updateManager.downloadAndInstall(release: release)
                                }
                            }
                            .font(.caption)
                        }

                    case .idle:
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            Text(updateManager.latestReleaseVersion.isEmpty
                                ? "A new version of \(AppName.displayName) is available!"
                                : "\(AppName.displayName) v\(updateManager.latestReleaseVersion) is available!")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("What's New") {
                                updateManager.showReleaseNotes()
                            }
                            .font(.caption)
                            Button("Update Now") {
                                if let release = updateManager.latestRelease {
                                    updateManager.downloadAndInstall(release: release)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    // MARK: Build

    private var buildInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Build number")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(appBuildNumber)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 12) {
                Text(buildDiagnosticsText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    copyBuildDiagnostics()
                } label: {
                    Label(copiedBuildInfo ? "Copied" : "Copy", systemImage: copiedBuildInfo ? "checkmark" : "doc.on.doc")
                }
                .font(.caption)
            }
        }
    }

    private func copyBuildDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildDiagnosticsText, forType: .string)
        copiedBuildInfo = true

        copiedBuildInfoResetWorkItem?.cancel()

        let resetWorkItem = DispatchWorkItem {
            copiedBuildInfo = false
            copiedBuildInfoResetWorkItem = nil
        }
        copiedBuildInfoResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: resetWorkItem)
    }

    // MARK: Speech Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = engineStatus {
                Label("Running on this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                engineInfoRow("Speech recognition", status.speechDescription)
                engineInfoRow("Cleanup model", status.cleanupDescription)
                engineInfoRow("Vocabulary boosting", status.boosting ? "On" : "Off")
                engineInfoRow("Learning from corrections", status.learning ? "On (\(status.learnedTerms) learned)" : "Off")
                engineInfoRow("Screen words", status.screenWords ? "On" : "Off")
                Text("Your voice and text stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Engine options are set in Terminal with freeflowctl, for example freeflowctl boost on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if engineChecked {
                Label("Not running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(AppName.displayName) needs its engine to transcribe. Install or restart it (Apple Silicon) with this command in Terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EngineInstallCommandView()
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Check again") {
                Task { await refreshEngine() }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .task { await refreshEngine() }
    }

    private func refreshEngine() async {
        engineStatus = await LocalEngine.probe()
        engineChecked = true
    }

    private func engineInfoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            DictationShortcutEditor { isCapturing in
                if isCapturing {
                    appState.suspendHotkeyMonitoringForShortcutCapture()
                } else {
                    appState.resumeHotkeyMonitoringAfterShortcutCapture()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shortcut Start Delay")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(appState.shortcutStartDelayMilliseconds) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $appState.shortcutStartDelay,
                    in: 0...0.5,
                    step: 0.025
                )

                Text("Applies before recording starts for both hold and tap shortcuts. Stopping still happens immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Double-tap Hold to Talk to lock recording", isOn: $appState.doubleTapToToggleEnabled)
                    .disabled(!appState.hasEnabledHoldShortcut)

                Text("Keeps recording after you release, as if you had used Tap to Toggle. Press the shortcut again to stop. A single quick tap takes 0.3 seconds longer to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Recording Overlay

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            OverlayStyleOptionRow(
                title: "Minimalist menu-bar overlay",
                subtitle: "Two slim wings flank the camera notch and stay inside the menu bar. Never covers app tabs or toolbars.",
                isMinimalist: true,
                selection: $useCompactOverlay
            )
            OverlayStyleOptionRow(
                title: "Drop-down pill",
                subtitle: "Single pill hangs below the menu bar during recording. Larger and more visible, but covers a thin strip of whatever app is active.",
                isMinimalist: false,
                selection: $useCompactOverlay
            )

            Toggle("Show recording timer", isOn: $showRecordingTimer)
            Text("When off, the minimalist overlay shows a waveform instead of the timer, and the drop-down pill hides the timer. Applies to the next recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            overlayDisplaySection
        }
    }

    // MARK: Audio During Dictation

    private var dictationAudioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Mute audio when dictation starts",
                isOn: $appState.dictationAudioInterruptionEnabled
            )

            Text("\(AppName.displayName) restores the audio state it changed when dictation ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Picks which physical display the recording overlay drops down on.
    /// Without this, AppKit defaults to "the screen with the active key
    /// window" (NSScreen.main), which makes the pill follow focus across
    /// monitors — disorienting on multi-display setups.
    private var overlayDisplaySection: some View {
        HStack {
            Text("Show on")
                .font(.system(size: 13))
            Spacer()
            Picker("", selection: $overlayDisplayID) {
                Text("Active window (default)").tag(0)
                Text("Primary display").tag(-1)
                ForEach(connectedScreenEntries, id: \.tag) { entry in
                    Text(entry.name).tag(entry.tag)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Show on")
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
        // Re-query NSScreen.screens whenever the display arrangement
        // changes so newly-attached monitors appear in the menu without
        // reopening Settings. screensVersion is just a cache-buster.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screensVersion &+= 1
        }
    }

    private var connectedScreenEntries: [(name: String, tag: Int)] {
        _ = screensVersion
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (name: screen.localizedName, tag: Int(id))
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use active window context", isOn: $appState.contextCaptureEnabled)

            Text("Uses words on screen to help with names and terminology. Turn off to skip screenshots; accuracy may decrease.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Preserve exact wording", isOn: $appState.preserveExactWording)

            Text("The default for dictation; each shortcut can override it below. When on, \(AppName.displayName) skips the cleanup step and pastes the transcript verbatim — filler words, informal phrasing, and explicit language are all preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcut overrides")
                    .font(.caption.weight(.semibold))

                Picker("Hold to Talk", selection: $appState.holdShortcutCleanupPreference) {
                    Text("Use global setting").tag(ShortcutCleanupPreference.inherit)
                    Text("Preserve exact wording").tag(ShortcutCleanupPreference.preserveExactWording)
                    Text("Cleanup").tag(ShortcutCleanupPreference.cleanup)
                }
                .pickerStyle(.menu)

                Picker("Tap to Toggle", selection: $appState.toggleShortcutCleanupPreference) {
                    Text("Use global setting").tag(ShortcutCleanupPreference.inherit)
                    Text("Preserve exact wording").tag(ShortcutCleanupPreference.preserveExactWording)
                    Text("Cleanup").tag(ShortcutCleanupPreference.cleanup)
                }
                .pickerStyle(.menu)

                Text("Use global setting follows Preserve exact wording above. Cleanup removes fillers and applies corrections. Each recording keeps its starting choice, even when switching from hold to toggle. Menu-bar recordings use the global setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    // MARK: Text insertion

    private var textInsertionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Insert into the original field", isOn: $appState.originalFieldInsertionEnabled)

            Text("Keep dictation in the field where recording began, even after switching apps. Off by default; applies to new dictations. Pasting or pressing Return may briefly bring the original app forward, then restore your previous focus when possible.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            Toggle("Say \"press enter\" to submit after paste", isOn: $appState.isPressEnterVoiceCommandEnabled)

            Text("When the transcription ends with \"press enter\", \(AppName.displayName) removes those words before cleanup, pastes the remaining transcript, then presses Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Preserve clipboard after paste", isOn: $appState.preserveClipboard)

            Text("\(AppName.displayName) will temporarily place the transcript on your clipboard to paste it, then restore whatever was there before. If you copy something else before the restore happens, \(AppName.displayName) leaves it alone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 2)

            Toggle("Keep dictations in clipboard history", isOn: $appState.keepDictationInClipboardHistory)

            Text("When on, your clipboard manager (Paste, Raycast, Maccy, etc.) records each dictation so you can find it in your recent history. When off, \(AppName.displayName) marks dictations transient and your clipboard manager skips them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select which microphone to use for recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                MicrophoneOptionRow(
                    name: "System Default",
                    isSelected: appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty,
                    action: { appState.selectedMicrophoneID = "default" }
                )
                ForEach(appState.availableMicrophones) { device in
                    MicrophoneOptionRow(
                        name: device.name,
                        isSelected: appState.selectedMicrophoneID == device.uid,
                        action: { appState.selectedMicrophoneID = device.uid }
                    )
                }
            }
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
        }
    }

    // MARK: Sound Volume

    private var soundVolumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Play alert sounds", isOn: $appState.alertSoundsEnabled)

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: $appState.soundVolume, in: 0...1, step: 0.1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("\(Int(appState.soundVolume * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!appState.alertSoundsEnabled)
            .opacity(appState.alertSoundsEnabled ? 1 : 0.5)

            HStack(spacing: 8) {
                Button("Preview") {
                    let muted = SystemAudioStatus.isDefaultOutputMuted()
                    let volume = SystemAudioStatus.defaultOutputVolume()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMutedHint = muted || (volume ?? 1) < 0.10
                    }
                    appState.playAlertSound(named: "Tink")
                }
                .font(.caption)
                .disabled(!appState.alertSoundsEnabled)

                if showMutedHint {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.orange)
                        Text("System volume is muted or very low. Unmute to hear the preview.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .transition(.opacity)
                }
            }
        }
        .onChange(of: appState.alertSoundsEnabled) { enabled in
            if !enabled { showMutedHint = false }
        }
    }

    // MARK: Custom Vocabulary

    private func commitCustomVocabulary() {
        let trimmed = customVocabularyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if appState.customVocabulary != trimmed {
            appState.customVocabulary = trimmed
        }
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words and phrases to preserve during post-processing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customVocabularyInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .focused($customVocabularyFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: customVocabularyFocused) { focused in
                    if !focused { commitCustomVocabulary() }
                }

            Text("Separate entries with commas, new lines, or semicolons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Microphone",
                icon: "mic.fill",
                granted: micPermissionGranted,
                action: {
                    appState.requestMicrophoneAccess { granted in
                        micPermissionGranted = granted
                    }
                }
            )

            permissionRow(
                title: "Accessibility",
                icon: "hand.raised.fill",
                granted: appState.hasAccessibility,
                action: {
                    appState.openAccessibilitySettings()
                }
            )

            permissionRow(
                title: "Screen Recording",
                icon: "camera.viewfinder",
                granted: appState.hasScreenRecordingPermission,
                action: {
                    appState.requestScreenCapturePermission()
                }
            )
        }
    }

    private func permissionRow(title: String, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access") {
                    action()
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func checkMicPermission() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

}

// MARK: - Microphone Option Row

struct MicrophoneOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pipeline Step View

struct PipelineStepView<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Audio Player

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish?()
        }
    }
}

struct AudioPlayerView: View {
    let audioURL: URL
    @State private var player: AVAudioPlayer?
    @State private var delegate = AudioPlayerDelegate()
    @State private var isPlaying = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * progress), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)

            Text("\(formatDuration(elapsed)) / \(formatDuration(duration))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            loadDuration()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func loadDuration() {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        if let p = try? AVAudioPlayer(contentsOf: audioURL) {
            duration = p.duration
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: audioURL)
                delegate.onFinish = {
                    self.stopPlayback()
                }
                p.delegate = delegate
                p.play()
                player = p
                isPlaying = true
                elapsed = 0
                startProgressTimer()
            } catch {}
        }
    }

    private func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        elapsed = 0
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if let p = player, p.isPlaying {
                elapsed = p.currentTime
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layoutSubviews(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layoutSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
