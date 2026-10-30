import SwiftUI

enum Palette {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let surface = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.29, green: 0.55, blue: 0.97)
    static let secondaryText = Color.white.opacity(0.62)
}

/// The LF’AZ VIDEOS wordmark from the sketches.
struct Brand: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("LF").kerning(5)
                Text("’").foregroundStyle(Palette.accent)
                Text("AZ").kerning(5)
            }.font(.system(size: 24, weight: .semibold, design: .default))
            Text("VIDEOS").font(.system(size: 8, weight: .medium)).kerning(7.5).foregroundStyle(Palette.secondaryText)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LF’AZ Videos")
    }
}

struct RoundIconButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void
    var size: CGFloat = 46
    /// Clear glass, for buttons that sit on artwork.
    var clear = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: size * 0.39, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassCircle(clear: clear)
        }.buttonStyle(.plain).accessibilityLabel(label).environment(\.colorScheme, .dark)
    }
}

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.stroke))
    }
}

extension View { func card() -> some View { modifier(Card()) } }

struct QualityBadge: View {
    var text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.3)))
    }
}
