import SwiftTerm
import SwiftUI

struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    /// 16 ANSI colors: normal 0–7 followed by bright 8–15.
    let ansi: [String]
    /// The rest of the app in this theme's colors (see `Chrome`).
    let chrome: Chrome

    /// The app around the terminal, so a theme is the whole look and not just the
    /// terminal: `canvas` behind content (conversations, the terminal itself, so it
    /// always equals `background`), `grouped` behind lists and settings, `card` for
    /// their rows. Mirrors iOS, where grouped pages sit a step deeper than content.
    struct Chrome: Hashable {
        let canvas: String
        let grouped: String
        let card: String
    }

    static let all: [TerminalTheme] = [.claudeDark, .claudeLight, .midnight, .daylight, .graphite, .ocean, .solarizedDark, .solarizedLight]

    static func named(_ id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .claudeDark
    }

    /// Warm charcoal with a terracotta cursor, after Claude's dark interface.
    static let claudeDark = TerminalTheme(
        id: "claude-dark", name: String(localized: "Claude 夜"), isDark: true,
        background: "#262624", foreground: "#E8E6DC", cursor: "#D97757", selection: "#D9775750",
        ansi: ["#1F1E1D", "#E0685A", "#9DB37E", "#E5B567", "#6A9BCC", "#C58FB5", "#7FB8B0", "#C9C6BB",
               "#6B6A65", "#EE8672", "#B4C996", "#F0C888", "#8DB3DB", "#D6A9C9", "#9CCBC4", "#FAF9F5"],
        chrome: Chrome(canvas: "#262624", grouped: "#1F1E1D", card: "#2B2A27")
    )

    /// Ivory paper with terracotta accents, after Claude's light interface.
    static let claudeLight = TerminalTheme(
        id: "claude-light", name: String(localized: "Claude 昼"), isDark: false,
        background: "#FAF9F5", foreground: "#3D3929", cursor: "#D97757", selection: "#D9775733",
        ansi: ["#3D3929", "#B8412E", "#5E7A3C", "#A0680E", "#3D6E9E", "#8F4F7E", "#3F7F78", "#8A877C",
               "#6B6A65", "#D0583F", "#788C5D", "#C0841F", "#6A9BCC", "#A8699A", "#56968E", "#B0AEA5"],
        chrome: Chrome(canvas: "#FAF9F5", grouped: "#F5F4EE", card: "#FFFFFF")
    )

    /// Built from the dark-mode system colors (systemRed, systemBlue, …).
    static let midnight = TerminalTheme(
        id: "midnight", name: String(localized: "午夜"), isDark: true,
        background: "#1C1C1E", foreground: "#F2F2F7", cursor: "#0A84FF", selection: "#0A84FF55",
        ansi: ["#1C1C1E", "#FF453A", "#32D74B", "#FFD60A", "#0A84FF", "#BF5AF2", "#64D2FF", "#D1D1D6",
               "#636366", "#FF6961", "#5CE07A", "#FFE55C", "#409CFF", "#DA8FFF", "#8BE0FF", "#FFFFFF"],
        chrome: Chrome(canvas: "#1C1C1E", grouped: "#000000", card: "#1C1C1E")
    )

    /// Built from the light-mode system colors, darkened where needed for contrast on white.
    static let daylight = TerminalTheme(
        id: "daylight", name: String(localized: "日光"), isDark: false,
        background: "#FFFFFF", foreground: "#1D1D1F", cursor: "#007AFF", selection: "#007AFF33",
        ansi: ["#1D1D1F", "#D70015", "#248A3D", "#A05A00", "#0040DD", "#8944AB", "#0071A4", "#8E8E93",
               "#48484A", "#FF3B30", "#34C759", "#C93400", "#007AFF", "#AF52DE", "#30B0C7", "#C7C7CC"],
        chrome: Chrome(canvas: "#FFFFFF", grouped: "#F2F2F7", card: "#FFFFFF")
    )

    static let graphite = TerminalTheme(
        id: "graphite", name: String(localized: "石墨"), isDark: true,
        background: "#262628", foreground: "#D8D8DC", cursor: "#A0A0A8", selection: "#8E8E9355",
        ansi: ["#262628", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
               "#5C6370", "#F08A93", "#B5DD98", "#F2D29B", "#86C4F5", "#D99BEA", "#7DCDD6", "#FFFFFF"],
        chrome: Chrome(canvas: "#262628", grouped: "#1D1D1F", card: "#2E2E31")
    )

    static let ocean = TerminalTheme(
        id: "ocean", name: String(localized: "深海"), isDark: true,
        background: "#0E1726", foreground: "#DCE6F2", cursor: "#5AC8FA", selection: "#5AC8FA44",
        ansi: ["#0E1726", "#FF6B6B", "#4FD6A5", "#F7D774", "#4DA3FF", "#B18CFF", "#5AC8FA", "#B8C4D4",
               "#4A5A70", "#FF8E8E", "#7AE8C0", "#FBE59E", "#7DBCFF", "#C9AEFF", "#8FDBFC", "#FFFFFF"],
        chrome: Chrome(canvas: "#0E1726", grouped: "#0A111D", card: "#15213A")
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: String(localized: "Solarized 暗"), isDark: true,
        background: "#002B36", foreground: "#93A1A1", cursor: "#93A1A1", selection: "#07364288",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#586E75", "#CB4B16", "#93A1A1", "#839496", "#657B83", "#6C71C4", "#93A1A1", "#FDF6E3"],
        chrome: Chrome(canvas: "#002B36", grouped: "#00222B", card: "#073642")
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: String(localized: "Solarized 亮"), isDark: false,
        background: "#FDF6E3", foreground: "#586E75", cursor: "#586E75", selection: "#EEE8D5CC",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"],
        chrome: Chrome(canvas: "#FDF6E3", grouped: "#F5EDD6", card: "#FFFCF3")
    )

    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map { hex in
            let (r, g, b, _) = Self.components(hex)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }
    }

    var backgroundColor: SwiftUI.Color { Self.color(background) }
    var foregroundColor: SwiftUI.Color { Self.color(foreground) }

    static func color(_ hex: String) -> SwiftUI.Color {
        let (r, g, b, a) = components(hex)
        return SwiftUI.Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA" into 0…1 components.
    static func components(_ hex: String) -> (Double, Double, Double, Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        if digits.count == 8 {
            return (Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255,
                    Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255, 1)
    }
}

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

extension PlatformColor {
    convenience init(hex: String) {
        let (r, g, b, a) = TerminalTheme.components(hex)
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
