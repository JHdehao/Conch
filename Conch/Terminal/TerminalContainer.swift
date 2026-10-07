import SwiftTerm
import SwiftUI

/// Hosts a session's long-lived `TerminalView` and applies the appearance to it.
struct TerminalContainer {
    let session: TerminalSession
    let appearance: TerminalAppearance
    var isFocused: Bool

    @MainActor
    static func apply(_ appearance: TerminalAppearance, to view: TerminalView, translucent: Bool) {
        let theme = appearance.theme
        view.font = appearance.font.font(size: appearance.fontSize)
        view.installColors(theme.swiftTermPalette)
        view.nativeForegroundColor = PlatformColor(hex: theme.foreground)
        view.nativeBackgroundColor = PlatformColor(hex: theme.background)
        view.caretColor = PlatformColor(hex: theme.cursor)
        view.selectedTextBackgroundColor = PlatformColor(hex: theme.selection)
        view.backgroundOpacity = translucent ? appearance.opacity : 1
        view.getTerminal().setCursorStyle(appearance.cursor.style(blinking: appearance.cursorBlink))
        #if os(iOS)
        (view as? ConchTerminalView)?.appearance = appearance
        #endif
    }
}

#if os(macOS)
import AppKit

extension TerminalContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        let view = session.terminalView
        Self.apply(appearance, to: view, translucent: true)
        context.coordinator.lastAppearance = appearance
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        if context.coordinator.lastAppearance != appearance {
            Self.apply(appearance, to: view, translucent: true)
            context.coordinator.lastAppearance = appearance
        }
        if isFocused, !session.isDictating, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastAppearance: TerminalAppearance?
    }
}

/// Blurs the desktop behind the window, like Terminal.app with a translucent profile.
struct WindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
#else
import UIKit

extension TerminalContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalView {
        let view = session.terminalView
        Self.apply(appearance, to: view, translucent: false)
        context.coordinator.lastAppearance = appearance
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if context.coordinator.lastAppearance != appearance {
            Self.apply(appearance, to: view, translucent: false)
            context.coordinator.lastAppearance = appearance
        }
        if isFocused, session.state == .connected, !session.isDictating, !view.isFirstResponder {
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastAppearance: TerminalAppearance?
    }
}
#endif
