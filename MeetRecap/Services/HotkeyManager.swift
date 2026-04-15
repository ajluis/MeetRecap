import Foundation
import AppKit
import Combine

/// Registers global keyboard shortcuts for MeetRecap.
///
/// Uses `NSEvent.addGlobalMonitorForEvents` which, unlike CGEvent taps, does not
/// require Accessibility permissions. Sufficient for triggering app actions when
/// the app is in the background.
///
/// Defaults:
///   - Cmd+Shift+R — toggle recording
///   - Cmd+Shift+D — open dashboard
@MainActor
final class HotkeyManager: ObservableObject {
    @Published var enabled: Bool = true {
        didSet { enabled ? installMonitors() : removeMonitors() }
    }

    /// Invoked when the toggle-recording hotkey fires.
    var onToggleRecording: (() -> Void)?

    /// Invoked when the open-dashboard hotkey fires.
    var onOpenDashboard: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        installMonitors()
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Installation

    private func installMonitors() {
        removeMonitors()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self = self, self.handle(event: event) {
                return nil  // consumed
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    // MARK: - Matching

    /// Returns true if the hotkey was recognized and handled.
    @discardableResult
    private func handle(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let expected: NSEvent.ModifierFlags = [.command, .shift]
        guard flags.contains(expected) else { return false }

        // charactersIgnoringModifiers is lowercase for letter keys when only
        // command/shift are held, regardless of shift state.
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch key {
        case "r":
            onToggleRecording?()
            return true
        case "d":
            onOpenDashboard?()
            return true
        default:
            return false
        }
    }
}
