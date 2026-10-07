import SwiftTerm
import SwiftUI

enum CursorShape: String, CaseIterable, Identifiable {
    case block, bar, underline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .block: String(localized: "方块")
        case .bar: String(localized: "竖线")
        case .underline: String(localized: "下划线")
        }
    }

    func style(blinking: Bool) -> CursorStyle {
        switch self {
        case .block: blinking ? .blinkBlock : .steadyBlock
        case .bar: blinking ? .blinkBar : .steadyBar
        case .underline: blinking ? .blinkUnderline : .steadyUnderline
        }
    }
}

enum TerminalFont: String, CaseIterable, Identifiable {
    case sfMono, menlo, courier

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .courier: "Courier New"
        }
    }

    func font(size: CGFloat) -> PlatformFont {
        switch self {
        case .sfMono: .monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo: PlatformFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .courier: PlatformFont(name: "CourierNewPSMT", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// UserDefaults keys for the appearance settings, shared by `@AppStorage` users.
enum AppearanceKey {
    static let lightTheme = "appearance.lightTheme"
    static let darkTheme = "appearance.darkTheme"
    static let followSystem = "appearance.followSystem"
    static let font = "appearance.font"
    static let fontSize = "appearance.fontSize"
    static let opacity = "appearance.opacity"
    static let cursor = "appearance.cursor"
    static let cursorBlink = "appearance.cursorBlink"
}

#if os(macOS)
let defaultFontSize = 13.0
#else
let defaultFontSize = 12.0
#endif

/// A resolved, value-type snapshot of the appearance settings.
struct TerminalAppearance: Equatable {
    var theme: TerminalTheme
    var font: TerminalFont
    var fontSize: Double
    var opacity: Double
    var cursor: CursorShape
    var cursorBlink: Bool
}

/// Keeps the whole app light or dark to match the terminal theme when the user
/// turned off following the system, not just the terminal's own colors.
@MainActor
enum AppColorScheme {
    static func apply() {
        let defaults = UserDefaults.standard
        let followSystem = defaults.object(forKey: AppearanceKey.followSystem) as? Bool ?? true
        let theme = TerminalTheme.named(defaults.string(forKey: AppearanceKey.darkTheme) ?? TerminalTheme.claudeDark.id)
        #if os(iOS)
        // Set on the windows themselves: this also covers sheets and extra windows,
        // and unlike preferredColorScheme(nil) it reliably goes back to the system.
        let style: UIUserInterfaceStyle = followSystem ? .unspecified : (theme.isDark ? .dark : .light)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
        #else
        NSApp.appearance = followSystem ? nil : NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        #endif
    }
}

/// Reads appearance settings from `@AppStorage` and resolves the theme for the
/// current light/dark mode.
struct AppearanceReader<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearanceKey.lightTheme) private var lightTheme = TerminalTheme.claudeLight.id
    @AppStorage(AppearanceKey.darkTheme) private var darkTheme = TerminalTheme.claudeDark.id
    @AppStorage(AppearanceKey.followSystem) private var followSystem = true
    @AppStorage(AppearanceKey.font) private var font = TerminalFont.sfMono
    @AppStorage(AppearanceKey.fontSize) private var fontSize = defaultFontSize
    @AppStorage(AppearanceKey.opacity) private var opacity = 0.88
    @AppStorage(AppearanceKey.cursor) private var cursor = CursorShape.bar
    @AppStorage(AppearanceKey.cursorBlink) private var cursorBlink = true

    @ViewBuilder var content: (TerminalAppearance) -> Content

    var body: some View {
        let themeID = followSystem && colorScheme == .light ? lightTheme : darkTheme
        content(TerminalAppearance(
            theme: .named(themeID),
            font: font,
            fontSize: fontSize,
            opacity: opacity,
            cursor: cursor,
            cursorBlink: cursorBlink
        ))
    }
}
