import SwiftUI

// Conch's look: the native structure (navigation, lists, sheets, Liquid Glass
// controls) dressed in the colors of the chosen terminal theme, applied the same
// way on every screen. The default Claude themes give Claude's warm palette.
//
// Two kinds of page, as in iOS itself: grouped pages (lists, settings) sit on a
// slightly deeper canvas with lighter cards; content pages (a conversation, the
// terminal) sit on one even surface, the terminal's own background.

/// The terminal theme in effect for this view's light/dark mode: the light theme
/// in light mode when following the system, otherwise the dark (or only) theme.
@propertyWrapper
struct CurrentTheme: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearanceKey.lightTheme) private var lightTheme = TerminalTheme.claudeLight.id
    @AppStorage(AppearanceKey.darkTheme) private var darkTheme = TerminalTheme.claudeDark.id
    @AppStorage(AppearanceKey.followSystem) private var followSystem = true

    var wrappedValue: TerminalTheme {
        .named(followSystem && colorScheme == .light ? lightTheme : darkTheme)
    }
}

extension TerminalTheme.Chrome {
    var canvasColor: Color { TerminalTheme.color(canvas) }
    var groupedColor: Color { TerminalTheme.color(grouped) }
    var cardColor: Color { TerminalTheme.color(card) }
}

private struct GroupedBackground: ViewModifier {
    @CurrentTheme private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.chrome.groupedColor)
    }
}

private struct CardBackground: ViewModifier {
    @CurrentTheme private var theme

    func body(content: Content) -> some View {
        content.listRowBackground(theme.chrome.cardColor)
    }
}

private struct CanvasBackground: ViewModifier {
    @CurrentTheme private var theme

    func body(content: Content) -> some View {
        content.background(theme.chrome.canvasColor)
    }
}

extension View {
    /// A List or Form on the theme's grouped canvas. Give its Sections `.conchCard()`.
    func conchGroupedBackground() -> some View {
        modifier(GroupedBackground())
    }

    /// The rows of a Section on `conchGroupedBackground()`.
    func conchCard() -> some View {
        modifier(CardBackground())
    }

    /// A content page (conversation, terminal surroundings) on the theme's canvas.
    func conchCanvas() -> some View {
        modifier(CanvasBackground())
    }
}

/// A small label next to a name ("MOSH", "TAILSCALE"): one quiet style everywhere.
struct ConchTag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

extension Color {
    /// A color that follows light and dark mode (including Conch's own override).
    init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        let (lr, lg, lb) = components(light)
        let (dr, dg, db) = components(dark)
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: 1)
                : UIColor(red: lr, green: lg, blue: lb, alpha: 1)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: 1)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: 1)
        })
        #endif
    }
}

/// Liquid Glass where the system has it, a material capsule before that.
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}

/// Shrinks a touch while pressed, the way system cards respond.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}
