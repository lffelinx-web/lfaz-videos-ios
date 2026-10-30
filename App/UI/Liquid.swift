import SwiftUI

/// iOS 26's Liquid Glass where available, with a plain fallback for iOS 17–18.
/// Inside a `LiquidContainer`, the selection pill keeps one `glassEffectID`, so moving
/// it to another item makes the glass flow over like a drop.
struct LiquidContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing, content: content) } else { content() }
    }
}

struct LiquidSelection: ViewModifier {
    var active: Bool
    var namespace: Namespace.ID
    var tint: Color = Palette.accent

    func body(content: Content) -> some View {
        content.background {
            if active {
                if #available(iOS 26, *) {
                    Capsule().fill(Color.clear)
                        .glassEffect(.regular.tint(tint.opacity(0.55)).interactive(), in: Capsule())
                        .glassEffectID("selection", in: namespace)
                } else {
                    Capsule().fill(tint.opacity(0.28)).overlay(Capsule().stroke(tint.opacity(0.7)))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
        }
    }
}

extension View {
    func liquidSelection(_ active: Bool, in namespace: Namespace.ID, tint: Color = Palette.accent) -> some View {
        modifier(LiquidSelection(active: active, namespace: namespace, tint: tint))
    }

    /// The floating bar's surface: glass on iOS 26, blurred material before.
    @ViewBuilder func liquidBar() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
    }
}

/// Season chips with the moving drop of glass under the selected one.
struct LiquidChips<ID: Hashable>: View {
    var items: [(id: ID, title: String)]
    @Binding var selection: ID
    @Namespace private var namespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LiquidContainer(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.id) { item in
                        let selected = item.id == selection
                        Button { withAnimation(.bouncy(duration: 0.45, extraBounce: 0.12)) { selection = item.id } } label: {
                            Text(item.title).font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 38)
                                .background(Capsule().fill(selected ? Color.clear : Palette.surface))
                                .liquidSelection(selected, in: namespace)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
            }
        }
        .padding(.horizontal, -20)
    }
}
