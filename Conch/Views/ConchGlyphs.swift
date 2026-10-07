import SwiftUI

// Icons SF Symbols doesn't have, drawn as template images so they take the
// surrounding tint like any symbol (accent in lists, primary in toolbars).

enum ConchGlyph {
    /// Tailscale's own mark: a 3×3 grid of dots whose middle row and bottom
    /// centre (a "T") are solid, the rest faded.
    static func tailscale(size: CGFloat = 22) -> Image {
        Image(size: CGSize(width: size, height: size)) { context in
            let cell = size / 3
            let radius = cell * 0.37
            let solid: Set<Int> = [3, 4, 5, 7]
            for index in 0..<9 {
                let center = CGPoint(x: cell * (CGFloat(index % 3) + 0.5), y: cell * (CGFloat(index / 3) + 0.5))
                let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(.black.opacity(solid.contains(index) ? 1 : 0.3)))
            }
        }
        .renderingMode(.template)
    }

    /// The menu mark: two long lines over a short one, as in Claude's app.
    static func menu(size: CGFloat = 20) -> Image {
        Image(size: CGSize(width: size, height: size)) { context in
            let thickness = size * 0.1
            let rows: [(y: CGFloat, length: CGFloat)] = [(0.27, 0.82), (0.5, 0.82), (0.73, 0.48)]
            for row in rows {
                var line = Path()
                line.move(to: CGPoint(x: size * 0.09, y: size * row.y))
                line.addLine(to: CGPoint(x: size * (0.09 + row.length), y: size * row.y))
                context.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            }
        }
        .renderingMode(.template)
    }
}

/// The app icon as a mark, for the welcome page.
struct ConchLogo: View {
    var size: CGFloat = 84

    var body: some View {
        Image("ConchLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.28), radius: size * 0.16, y: size * 0.08)
            .accessibilityHidden(true)
    }
}
