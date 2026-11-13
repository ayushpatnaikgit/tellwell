import SwiftUI
import AVFoundation
import Combine
import Foundation
import ServiceManagement

struct SetupView: View {
    var onComplete: () -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    // Local-first setup: the engine on this Mac replaces FreeFlow's API-key step. The toggle and copy-again
    // shortcuts, edit mode and overlay style keep their defaults and live in Settings.
    private enum SetupStep: Int, CaseIterable {
        case welcome = 0
        case engine
        case micPermission
        case accessibility
        case screenRecording
        case holdShortcut
        case vocabulary
        case launchAtLogin
        case testTranscription
        case ready
    }

    @State private var currentStep = SetupStep.welcome
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var accessibilityTimer: Timer?
    @State private var screenRecordingTimer: Timer?
    @State private var customVocabularyInput: String = ""
    @State private var engineStatus: LocalEngine.Status?
    @State private var engineChecked = false

    // Test transcription state
    private enum TestPhase: Equatable {
        case idle, recording, transcribing, done
    }
    @State private var testPhase: TestPhase = .idle
    @State private var testAudioRecorder: AudioRecorder? = nil
    @State private var testAudioLevel: Float = 0.0
    @State private var testTranscript: String = ""
    @State private var testError: String? = nil
    @State private var testAudioLevelCancellable: AnyCancellable? = nil
    @State private var testMicPulsing = false
    @State private var holdShortcutValidationMessage: String?
    @State private var toggleShortcutValidationMessage: String?
    @State private var copyAgainShortcutValidationMessage: String?
    @State private var isCapturingHoldShortcut = false
    @State private var isCapturingToggleShortcut = false
    @State private var isCapturingCopyAgainShortcut = false
    @StateObject private var testHotkeyHarness = SetupTestHotkeyHarness()
    @AppStorage("use_compact_overlay") private var useCompactOverlay = true

    private let totalSteps: [SetupStep] = SetupStep.allCases
    private var isCapturingShortcut: Bool {
        isCapturingHoldShortcut || isCapturingToggleShortcut || isCapturingCopyAgainShortcut
    }

    var body: some View {
        VStack(spacing: 0) {
            currentStepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical, 32)

            Divider()

            ZStack {
                stepIndicator

                HStack(alignment: .center) {
                    Group {
                        if currentStep != .welcome {
                            Button("Back") {
                                withAnimation {
                                    currentStep = previousStep(currentStep)
                                }
                            }
                        }
                    }

                    Spacer()

                    Group {
                        if currentStep != .ready {
                            if currentStep == .engine {
                                Button("Continue") {
                                    withAnimation { currentStep = nextStep(currentStep) }
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(engineStatus == nil)
                            } else if currentStep == .vocabulary {
                                Button("Continue") {
                                    saveCustomVocabularyAndContinue()
                                }
                                .keyboardShortcut(.defaultAction)
                            } else if currentStep == .testTranscription {
                                HStack(spacing: 10) {
                                    Button("Skip") {
                                        stopTestHotkeyMonitoring()
                                        withAnimation {
                                            currentStep = nextStep(currentStep)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)

                                    Button("Continue") {
                                        stopTestHotkeyMonitoring()
                                        withAnimation {
                                            currentStep = nextStep(currentStep)
                                        }
                                    }
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(testPhase != .done || testTranscript.isEmpty || testError != nil)
                                }
                            } else {
                                Button("Continue") {
                                    withAnimation {
                                        currentStep = nextStep(currentStep)
                                    }
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canContinueFromCurrentStep)
                            }
                        } else {
                            Button("Get Started") {
                                onComplete()
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 520, height: 680)
        .tint(TellWellBrand.accent)
        .onAppear {
            customVocabularyInput = appState.customVocabulary
            checkMicPermission()
            checkAccessibility()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            screenRecordingTimer?.invalidate()
            appState.resumeHotkeyMonitoringAfterShortcutCapture()
        }
        .onChange(of: isCapturingShortcut) { isCapturing in
            if isCapturing {
                appState.suspendHotkeyMonitoringForShortcutCapture()
            } else {
                appState.resumeHotkeyMonitoringAfterShortcutCapture()
            }
        }
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
        case .engine:
            engineStep
        case .micPermission:
            micPermissionStep
        case .accessibility:
            accessibilityStep
        case .screenRecording:
            screenRecordingStep
        case .holdShortcut:
            holdShortcutStep
        case .vocabulary:
            vocabularyStep
        case .launchAtLogin:
            launchAtLoginStep
        case .testTranscription:
            testTranscriptionStep
        case .ready:
            readyStep
        }
    }

    // MARK: - Steps

    var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)

            VStack(spacing: 6) {
                Text("Welcome to \(AppName.displayName)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Hold a key, speak, and clean text appears wherever you're typing.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                welcomeRow("lock.shield", "Private", "Speech recognition and cleanup run on your Mac. Nothing is uploaded.")
                welcomeRow("bolt", "Fast", "Text appears a fraction of a second after you stop speaking.")
                welcomeRow("text.badge.checkmark", "Types what you meant",
                           "Removes fillers, applies \"no wait, I mean\" corrections and spells your names right.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))

            Text("Built on FreeFlow by Zach Latta.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private func welcomeRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(TellWellBrand.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Finds the engine on this Mac, rechecking every 2 s so it picks up an install running in Terminal.
    var engineStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: engineStatus != nil ? "checkmark.seal.fill" : "cpu")
                .font(.system(size: 54))
                .foregroundStyle(engineStatus != nil ? Color.green : TellWellBrand.accent)

            Text("Speech Engine")
                .font(.title)
                .fontWeight(.bold)

            if let status = engineStatus {
                Text("\(AppName.displayName)'s engine is running on this Mac. Your voice and text stay on it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    engineRow("waveform", "Speech recognition", status.speechDescription)
                    engineRow("text.badge.checkmark", "Cleanup", status.cleanupDescription)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            } else if engineChecked {
                Text("\(AppName.displayName) runs speech recognition and cleanup on your Mac with a small engine. It isn't running yet: paste this into Terminal to install it. This step continues by itself once it's running.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                EngineInstallCommandView()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the engine (needs an Apple Silicon Mac)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Looking for the engine on this Mac...")
            }

            Spacer(minLength: 0)
        }
        .task {
            while !Task.isCancelled {
                let status = await LocalEngine.probe()
                engineStatus = status
                engineChecked = true
                if status != nil { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func engineRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(TellWellBrand.accent)
                .frame(width: 20)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
    }

    var micPermissionStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Microphone Access")
                .font(.title)
                .fontWeight(.bold)

            Text("\(AppName.displayName) needs access to your microphone to record audio for transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "mic.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Microphone")
                Spacer()
                if micPermissionGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        requestMicPermission()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

        }
    }

    var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Accessibility Access")
                .font(.title)
                .fontWeight(.bold)

            Text("\(AppName.displayName) needs Accessibility access to paste transcribed text into your apps.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "hand.raised.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Accessibility")
                Spacer()
                if accessibilityGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Open Settings") {
                        requestAccessibility()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

        }
        .onAppear {
            startAccessibilityPolling()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
        }
    }

    var screenRecordingStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Screen Recording")
                .font(.title)
                .fontWeight(.bold)

            Text("\(AppName.displayName) intelligently adapts the transcription to the current app you're working in (ex. spelling names in an email correctly).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("It needs this permission to see which app you're working in and any in-progress work. Nothing is stored on \(AppName.displayName)'s servers (\(AppName.displayName) doesn't have servers).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "camera.viewfinder")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Text("Screen Recording")
                Spacer()
                if appState.hasScreenRecordingPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        appState.requestScreenCapturePermission()
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

        }
        .onAppear {
            startScreenRecordingPolling()
        }
        .onDisappear {
            screenRecordingTimer?.invalidate()
        }
    }

    var holdShortcutStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Hold to Talk Shortcut")
                .font(.title)
                .fontWeight(.bold)

            Text("Choose the shortcut you want to hold while speaking.\nRelease it to stop unless you latch into tap mode later, or disable hold-to-talk entirely.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ShortcutRoleSection(
                role: .hold,
                selection: appState.holdShortcut,
                validationMessage: holdShortcutValidationMessage,
                isCapturing: $isCapturingHoldShortcut,
                onSelect: { binding in
                    holdShortcutValidationMessage = appState.setShortcut(binding, for: .hold)
                }
            )
                .padding(.top, 10)

            if appState.holdShortcut.usesFnKey {
                Text("Tip: If Fn opens Emoji picker, go to System Settings > Keyboard and change \"Press fn key to\" to \"Do Nothing\".")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

        }
    }

    var vocabularyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Custom Vocabulary")
                .font(.title)
                .fontWeight(.bold)

            Text("Add words and phrases that should be preserved in post-processing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Vocabulary")
                    .font(.headline)

                TextEditor(text: $customVocabularyInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 130)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                Text("Separate entries with commas, new lines, or semicolons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
    }

    var launchAtLoginStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Launch at Login")
                .font(.title)
                .fontWeight(.bold)

            Text("Start \(AppName.displayName) automatically when you log in so it's always ready.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "sunrise.fill")
                    .frame(width: 24)
                    .foregroundStyle(.blue)
                Toggle("Launch \(AppName.displayName) at login", isOn: $appState.launchAtLogin)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

        }
    }

    var testTranscriptionStep: some View {
        VStack(spacing: 20) {
            // Microphone picker
            VStack(spacing: 4) {
                Picker("Microphone:", selection: $appState.selectedMicrophoneID) {
                    Text("System Default").tag("default")
                    ForEach(appState.availableMicrophones) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .frame(maxWidth: 340)

                Text("You can change this later in the menu bar or settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Group {
                switch testPhase {
                case .idle:
                    VStack(spacing: 20) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                            .scaleEffect(testMicPulsing ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: testMicPulsing)

                        Text("Let's Try It Out!")
                            .font(.title)
                            .fontWeight(.bold)

                        Text(testShortcutPrompt)
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(10)

                        Text("Say anything — a sentence or two is perfect.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                case .recording:
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.65))
                                .frame(width: 100, height: 100)

                            Circle()
                                .stroke(Color.blue.opacity(0.8), lineWidth: 3)
                                .frame(width: 100, height: 100)
                                .shadow(color: .blue.opacity(0.5), radius: 10)

                            WaveformView(audioLevel: testAudioLevel)
                        }

                        Text("Listening...")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }

                case .transcribing:
                    VStack(spacing: 20) {
                        InlineTranscribingDots()

                        Text("Transcribing...")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }

                case .done:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)

                        if let error = testError {
                            Text("Something went wrong")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Text(retryShortcutPrompt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if testTranscript.isEmpty {
                            Text("No speech detected")
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            Text(retryShortcutPrompt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Perfect — \(AppName.displayName) is ready to go.")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(testTranscript)
                                .font(.body)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(10)
                                .transition(.move(edge: .bottom).combined(with: .opacity))

                            Text(retryShortcutPrompt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .transition(.opacity)
            .id(testPhase)

            Spacer()
        }
        .onAppear {
            appState.refreshAvailableMicrophones()
            testMicPulsing = true
            startTestHotkeyMonitoring()
        }
        .onDisappear {
            stopTestHotkeyMonitoring()
        }
    }

    var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)

            Text("\(AppName.displayName) lives in your menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                if appState.hasEnabledHoldShortcut {
                    HowToRow(icon: "keyboard", text: "Hold \(appState.holdShortcut.displayName) to record")
                }
                if appState.hasEnabledToggleShortcut {
                    HowToRow(icon: "switch.2", text: "Tap \(appState.toggleShortcut.displayName) to start and stop")
                }
                if appState.hasEnabledHoldShortcut && appState.hasEnabledToggleShortcut {
                    HowToRow(icon: "arrow.triangle.branch", text: "While holding, press the toggle shortcut to latch on")
                }
                if appState.isCommandModeEnabled {
                    switch appState.commandModeStyle {
                    case .automatic:
                        HowToRow(icon: "wand.and.stars", text: "With text selected, your normal shortcut transforms the selection")
                    case .manual:
                        HowToRow(
                            icon: "wand.and.stars",
                            text: "Hold \(appState.commandModeManualModifier.title) with your normal shortcut to transform selected text"
                        )
                    }
                }
                HowToRow(icon: "doc.on.clipboard", text: "Text is typed at your cursor & copied")
            }
            .padding(.top, 10)

        }
    }

    var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(totalSteps, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep ? Color.blue : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var canContinueFromCurrentStep: Bool {
        switch currentStep {
        case .micPermission:
            return micPermissionGranted
        case .accessibility:
            return accessibilityGranted
        case .screenRecording:
            return appState.hasScreenRecordingPermission
        case .testTranscription:
            return testPhase == .done && !testTranscript.isEmpty && testError == nil
        default:
            return true
        }
    }

    private var testShortcutPrompt: String {
        switch (appState.hasEnabledHoldShortcut, appState.hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(appState.holdShortcut.displayName) or tap \(appState.toggleShortcut.displayName)"
        case (true, false):
            return "Hold \(appState.holdShortcut.displayName)"
        case (false, true):
            return "Tap \(appState.toggleShortcut.displayName)"
        case (false, false):
            return "Use Start Dictating from the menu bar"
        }
    }

    private var retryShortcutPrompt: String {
        "\(testShortcutPrompt) to try again"
    }

    // MARK: - Helpers

    private func instructionRow(number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number + ".")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .tint(.blue)
        }
    }

    // MARK: - Actions

    func saveCustomVocabularyAndContinue() {
        appState.customVocabulary = customVocabularyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation {
            currentStep = nextStep(currentStep)
        }
    }

    private func previousStep(_ step: SetupStep) -> SetupStep {
        let previous = SetupStep(rawValue: step.rawValue - 1)
        return previous ?? .welcome
    }

    private func nextStep(_ step: SetupStep) -> SetupStep {
        let next = SetupStep(rawValue: step.rawValue + 1)
        return next ?? .ready
    }

    func checkMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
        default:
            break
        }
    }

    func requestMicPermission() {
        appState.requestMicrophoneAccess { granted in
            micPermissionGranted = granted
        }
    }

    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                checkAccessibility()
            }
        }
    }

    func requestAccessibility() {
        appState.openAccessibilitySettings()
    }

    func startScreenRecordingPolling() {
        screenRecordingTimer?.invalidate()
        screenRecordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                appState.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            }
        }
    }

    // MARK: - Test Transcription

    private func startTestHotkeyMonitoring() {
        testHotkeyHarness.onAction = { action in
            switch action {
            case .start:
                guard testPhase == .idle || testPhase == .done else { return }
                if testPhase == .done {
                    resetTest()
                }
                do {
                    let recorder = AudioRecorder()
                    recorder.onRecordingFailure = { [weak recorder] error in
                        guard let recorder else { return }
                        Task { @MainActor in
                            testAudioLevelCancellable?.cancel()
                            testAudioLevelCancellable = nil
                            testAudioLevel = 0.0
                            testHotkeyHarness.isTranscribing = false
                            testAudioRecorder = nil
                            testError = error.localizedDescription
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                testPhase = .done
                            }
                            recorder.cleanup()
                        }
                    }
                    try recorder.startRecording(deviceUID: appState.selectedMicrophoneID)
                    testAudioRecorder = recorder
                    testError = nil
                    testAudioLevelCancellable = recorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { level in
                            testAudioLevel = level
                        }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        testPhase = .recording
                    }
                } catch {
                    testHotkeyHarness.resetSession()
                    testError = error.localizedDescription
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        testPhase = .done
                    }
                }

            case .stop:
                guard testPhase == .recording, let recorder = testAudioRecorder else { return }
                testAudioLevelCancellable?.cancel()
                testAudioLevelCancellable = nil
                testAudioLevel = 0.0
                testHotkeyHarness.isTranscribing = true

                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    testPhase = .transcribing
                }
                recorder.stopRecording { url in
                    guard let url else {
                        Task { @MainActor in
                            testHotkeyHarness.isTranscribing = false
                            testAudioRecorder = nil
                            if testError == nil {
                                testError = "No audio file was created."
                            }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                testPhase = .done
                            }
                            recorder.cleanup()
                        }
                        return
                    }

                    Task {
                        do {
                            let service = try appState.makeTranscriptionService()
                            let transcript = try await service.transcribe(fileURL: url)
                            await MainActor.run {
                                testHotkeyHarness.isTranscribing = false
                                testAudioRecorder = nil
                                testTranscript = transcript
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    testPhase = .done
                                }
                            }
                        } catch {
                            await MainActor.run {
                                testHotkeyHarness.isTranscribing = false
                                testAudioRecorder = nil
                                testError = error.localizedDescription
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    testPhase = .done
                                }
                            }
                        }
                        await MainActor.run {
                            recorder.cleanup()
                        }
                    }
                }

            case .switchedToToggle, .awaitDoubleTap:
                break
            }
        }

        do {
            try testHotkeyHarness.start(configuration: ShortcutConfiguration(
                hold: appState.holdShortcut,
                toggle: appState.toggleShortcut
            ), startDelay: appState.shortcutStartDelay)
        } catch {
            testError = error.localizedDescription
            testPhase = .done
        }
    }

    private func stopTestHotkeyMonitoring() {
        testHotkeyHarness.stop()
        testAudioLevelCancellable?.cancel()
        testAudioLevelCancellable = nil
        if let recorder = testAudioRecorder, recorder.isRecording {
            recorder.cancelRecording()
        }
        testAudioRecorder = nil
    }

    private func resetTest() {
        testPhase = .idle
        testTranscript = ""
        testError = nil
        testAudioLevel = 0.0
        testMicPulsing = true
        testHotkeyHarness.isTranscribing = false
        testHotkeyHarness.resetSession()
        if let recorder = testAudioRecorder {
            if recorder.isRecording {
                recorder.cancelRecording()
            }
            testAudioRecorder = nil
        }
    }

}

private struct InlineTranscribingDots: View {
    @State private var activeDot = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue.opacity(activeDot == index ? 1.0 : 0.3))
                    .frame(width: 12, height: 12)
                    .scaleEffect(activeDot == index ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: activeDot)
            }
        }
        .onReceive(timer) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}

struct HowToRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

/// Mini visual preview of one overlay style for the setup-flow option cards.
/// Stylized MacBook top edge with the recording UI drawn as wings or pill.
struct OverlayStylePreview: View {
    let isMinimalist: Bool

    private let frameWidth: CGFloat = 110
    private let frameHeight: CGFloat = 56
    private let menuBarHeight: CGFloat = 8
    private let notchWidth: CGFloat = 26
    private let notchHeight: CGFloat = 8

    var body: some View {
        ZStack(alignment: .top) {
            // Screen background — represents the host app behind the bar.
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                )

            // Menu bar strip.
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: menuBarHeight)

            // Tab strip stand-in below menu bar (so collisions read).
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.18))
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, menuBarHeight + 4)

            // Notch (always visible).
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 3,
                topTrailingRadius: 0
            )
            .fill(Color.black)
            .frame(width: notchWidth, height: notchHeight)

            // Style-specific overlay rendering.
            if isMinimalist {
                // Two slim wings flanking the notch, inside menu bar height.
                HStack(spacing: notchWidth) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 3,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(Color.black)
                    .frame(width: 16, height: notchHeight)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 3,
                        topTrailingRadius: 0
                    )
                    .fill(Color.black)
                    .frame(width: 16, height: notchHeight)
                }
            } else {
                // Drop-down pill hanging below the menu bar from the notch.
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 5,
                    bottomTrailingRadius: 5,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
                .frame(width: notchWidth + 10, height: notchHeight + 12)
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Shared picker row used by both Setup and Settings so the UI matches in both.
struct OverlayStyleOptionRow: View {
    let title: String
    let subtitle: String
    let isMinimalist: Bool
    @Binding var selection: Bool

    var body: some View {
        let isSelected = (selection == isMinimalist)
        Button(action: {
            selection = isMinimalist
        }) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                OverlayStylePreview(isMinimalist: isMinimalist)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
