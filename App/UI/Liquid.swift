import SwiftUI

/// A track of glass (Liquid Glass on iOS 26, material before) with a lighter lens that
/// slides under the selected item, as in the system tab bar. The lens is drawn behind the
/// label inside the same glass, so the text always stays on top.
struct LiquidSelection: ViewModifier {
    var active: Bool
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.background {
            if active {
                Capsule().fill(Color.white.opacity(0.16))
                    .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                    .matchedGeometryEffect(id: "lens", in: namespace)
            }
        }
    }
}

extension View {
    func liquidSelection(_ active: Bool, in namespace: Namespace.ID) -> some View {
        modifier(LiquidSelection(active: active, namespace: namespace))
    }

    /// Glass on iOS 26, blurred material before.
    @ViewBuilder func liquidBar() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
    }

    /// A round glass button background.
    @ViewBuilder func glassCircle(clear: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(clear ? .clear.interactive() : .regular.interactive(), in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke))
        }
    }

    /// One piece of a `GlassGroup`; pieces sharing an id morph into each other when the
    /// layout changes.
    @ViewBuilder func glassPiece<S: Shape>(_ shape: S, id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape).glassEffectID(id, in: namespace)
        } else {
            background(.ultraThinMaterial, in: shape).overlay(shape.stroke(Color.white.opacity(0.12)))
                .matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

/// Lets nearby glass pieces blend and morph on iOS 26; a plain group before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing) { content() } } else { content() }
    }
}

/// Season chips on one glass track with the sliding lens under the selected season.
struct LiquidChips<ID: Hashable>: View {
    var items: [(id: ID, title: String)]
    @Binding var selection: ID
    @Namespace private var namespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(items, id: \.id) { item in
                        let selected = item.id == selection
                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { selection = item.id; proxy.scrollTo(item.id, anchor: .center) }
                        } label: {
                            Text(item.title)
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                                .padding(.horizontal, 16).frame(height: 36)
                                .liquidSelection(selected, in: namespace)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(4)
                .liquidBar()
                .padding(.horizontal, 20).padding(.vertical, 2)
            }
            .padding(.horizontal, -20)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .environment(\.colorScheme, .dark)
    }
}
