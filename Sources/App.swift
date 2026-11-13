import AppKit
import SwiftUI

@main
struct TellWellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.appState)
        }
    }
}

@MainActor
struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var notificationManager = VocabularyNotificationManager.shared

    private var iconName: String {
        if appState.isRecording { return "record.circle" }
        if appState.isTranscribing { return "ellipsis.circle" }
        return "waveform"
    }

    var body: some View {
        HStack(spacing: 4) {
            if notificationManager.showCheckmark {
                Image(systemName: "checkmark")
            }
            if !appState.isRecording && !appState.isTranscribing {
                Image(nsImage: AppBuild.isDevBundle ? StampedMenuBarIcon.templateImage : TellWellMenuBarIcon.templateImage)
                    .renderingMode(.template)
            } else {
                Image(systemName: iconName)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notificationManager.showCheckmark)
    }
}

/// TellWell's mark in the menu bar: the "sound T", reduced to three bars (a tall stem between two short ones)
/// so it stays legible at 18 pt. Template image, so macOS tints it for light and dark menu bars.
enum TellWellMenuBarIcon {
    static let bars: [NSRect] = [  // in an 18x18 pt box, origin bottom-left
        NSRect(x: 2.9, y: 10.4, width: 2.9, height: 5.0),
        NSRect(x: 7.55, y: 1.1, width: 2.9, height: 15.8),
        NSRect(x: 12.2, y: 10.4, width: 2.9, height: 5.0),
    ]

    static let templateImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Dev builds: the same three bars cut out of a rounded square, so a developer can tell the bundles apart.
enum StampedMenuBarIcon {
    static let templateImage: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            path.append(NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3))
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (4.5,  8.5, 4.0),
                (8.25, 2.5, 11.0),
                (12.0, 8.5, 4.0),
            ]
            for bar in bars {
                path.append(NSBezierPath(
                    roundedRect: NSRect(x: bar.x, y: bar.y, width: 1.5, height: bar.h),
                    xRadius: 0.75, yRadius: 0.75
                ))
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
