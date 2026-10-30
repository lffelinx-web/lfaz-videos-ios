import SwiftUI

@main
struct LFAZVideosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Palette.accent).preferredColorScheme(.dark)
        }
    }
}

enum Route: Hashable {
    case movie(String)
    case show(String)
    case list(title: String, ids: [String])
}

/// The bar has two faces, as in the sketches: Inicio · Biblioteca · Buscar with the profile
/// circle on the right, and inside Biblioteca the menu circle on the left plus
/// Películas · Series · Videos.
enum AppTab: Hashable {
    case home, search, profile
    case section(LibrarySection)

    var isLibrary: Bool { if case .section = self { return true } else { return false } }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var settings = false

    var body: some View {
        MainTabs(openSettings: { settings = true })
            .background(Palette.background.ignoresSafeArea())
            .sheet(isPresented: $settings) { SettingsView() }
            .fullScreenCover(item: $store.vlcSession) { session in
                VLCPlayerScreen(request: session.request, url: session.url,
                                onProgress: { store.record(session.request.id, position: $0, duration: $1) },
                                onClose: { store.saveProgress(); store.vlcSession = nil })
            }
            .alert("No se pudo completar", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("Aceptar", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
            .task {
                await BlockCache.shared.configure(megabytes: UserDefaults.standard.object(forKey: "cacheMB") as? Int ?? 2048)
                await store.checkConnection()
                store.enrichMetadata()
            }
            .onAppear { if store.account == nil { settings = true } }
    }
}

extension View {
    /// Destinations shared by every navigation stack.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .movie(let id): MovieDetailView(id: id)
            case .show(let id): ShowDetailView(id: id)
            case .list(let title, let ids): TitleGridView(title: title, ids: ids)
            }
        }
    }
}

/// One navigation stack per tab, kept alive while hidden so every tab comes back where it
/// was. The glass bar floats over them and hides inside detail screens.
struct MainTabs: View {
    var openSettings: () -> Void
    @State private var tab = AppTab.home
    @State private var lastMain = AppTab.home
    @State private var lastSection = LibrarySection.movies
    @State private var opened: [AppTab] = [.home]
    @State private var paths: [AppTab: NavigationPath] = [:]

    private var atRoot: Bool { paths[tab]?.isEmpty ?? true }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(opened, id: \.self) { item in
                    NavigationStack(path: Binding(get: { paths[item] ?? NavigationPath() }, set: { paths[item] = $0 })) {
                        screen(item).routeDestinations()
                    }
                    .opacity(item == tab ? 1 : 0)
                    .allowsHitTesting(item == tab)
                    .accessibilityHidden(item != tab)
                }
            }
            .overlay {
                VStack(spacing: 0) {
                    // Keeps the clock readable when content scrolls under the status bar.
                    LinearGradient(colors: [Palette.background.opacity(0.92), Palette.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.safeAreaInsets.top + 16)
                        .allowsHitTesting(false)
                        .opacity(atRoot ? 1 : 0)
                    Spacer(minLength: 0)
                    if atRoot {
                        GlassTabBar(tab: tab, select: select)
                            .padding(.horizontal, 18)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom - 14, 12))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.2), value: atRoot)
            }
        }
    }

    @ViewBuilder private func screen(_ item: AppTab) -> some View {
        switch item {
        case .home: HomeView(openSettings: openSettings)
        case .search: SearchView()
        case .profile: ProfileView(openSettings: openSettings)
        case .section(let section): LibraryView(section: section, openSearch: { select(.search) })
        }
    }

    /// Biblioteca opens the last library section and the menu circle the last main tab;
    /// tapping the current tab again goes back to its first screen.
    private func select(_ item: AppTab) {
        var target = item
        if item == .section(.movies) && !tab.isLibrary { target = .section(lastSection) }
        if item == .home && tab.isLibrary { target = lastMain }
        if target == tab { paths[target] = NavigationPath(); return }
        if !opened.contains(target) { opened.append(target) }
        withAnimation(.bouncy(duration: 0.45, extraBounce: 0.08)) { tab = target }
        if case .section(let section) = target { lastSection = section } else { lastMain = target }
    }
}

/// Room left at the bottom of scrolling screens so the last row clears the floating bar.
enum BarInset {
    static let bottom: CGFloat = 104
}

/// The floating bar: one glass capsule with the tabs and one glass circle beside it that
/// morphs from the profile (right) to the menu (left) when entering Biblioteca.
struct GlassTabBar: View {
    var tab: AppTab
    var select: (AppTab) -> Void
    @Namespace private var namespace
    /// Where the floating lens is while a finger slides over the tabs, in bar coordinates.
    @State private var lens: CGRect?
    private let height: CGFloat = 62
    private let circle: CGFloat = 56

    var body: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if tab.isLibrary {
                    circleButton(label: "Volver al menú principal", action: { select(.home) }) {
                        Image(systemName: "square.grid.2x2.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                    }
                    capsule(LibrarySection.allCases.map { section in
                        TabItem(title: section.title, symbol: section.tabSymbol, selected: tab == .section(section)) { select(.section(section)) }
                    })
                } else {
                    capsule([
                        TabItem(title: "Inicio", symbol: "house.fill", selected: tab == .home) { select(.home) },
                        TabItem(title: "Biblioteca", symbol: "books.vertical.fill", selected: false) { select(.section(.movies)) },
                        TabItem(title: "Buscar", symbol: "magnifyingglass", selected: tab == .search) { select(.search) },
                    ])
                    circleButton(label: "Perfil, Mi lista y Descargas", action: { select(.profile) }) {
                        ProfileAvatar(size: 42)
                            .overlay(Circle().stroke(Palette.accent, lineWidth: tab == .profile ? 2.5 : 0).padding(-3))
                    }
                    .accessibilityAddTraits(tab == .profile ? .isSelected : [])
                }
            }
        }
        .coordinateSpace(.named("bar"))
        // The lens sits outside the glass group so it floats over the capsule instead of
        // melting into it.
        .overlay(alignment: .topLeading) {
            if let lens {
                DragLens()
                    .frame(width: lens.width, height: lens.height)
                    .offset(x: lens.minX, y: lens.minY)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private func capsule(_ items: [TabItem]) -> some View {
        TabCapsule(items: items, lens: $lens)
            .padding(4)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .glassPiece(Capsule(), id: "capsule", in: namespace)
    }

    private func circleButton<Label: View>(label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Label) -> some View {
        Button(action: action) {
            content().frame(width: circle, height: circle).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassPiece(Circle(), id: "circle", in: namespace)
        .accessibilityLabel(label)
    }
}

struct TabItem {
    var title: String
    var symbol: String
    var selected: Bool
    var action: () -> Void
}

/// The tabs inside the capsule. Touching shows a glass lens under the finger that can be
/// slid across the tabs, as in the system tab bar; lifting the finger selects the tab under it.
struct TabCapsule: View {
    var items: [TabItem]
    @Binding var lens: CGRect?
    @State private var dragX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / CGFloat(max(items.count, 1))
            let selected = items.firstIndex { $0.selected }
            let highlighted = dragX.map { index(at: $0, width: width) } ?? selected
            ZStack(alignment: .leading) {
                if dragX == nil, let selected {
                    Capsule().fill(Color.white.opacity(0.16))
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                        .frame(width: width)
                        .offset(x: width * CGFloat(selected))
                }
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        label(items[i], highlighted: i == highlighted).frame(width: width)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, width / 2), geo.size.width - width / 2)
                        let frame = geo.frame(in: .named("bar"))
                        let rect = CGRect(x: frame.minX + x - width / 2 - 6, y: frame.minY - 8, width: width + 12, height: frame.height + 16)
                        if dragX == nil {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { dragX = x; lens = rect }
                        } else {
                            dragX = x; lens = rect
                        }
                    }
                    .onEnded { value in
                        let item = items[index(at: value.location.x, width: width)]
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) { dragX = nil; lens = nil }
                        item.action()
                    }
            )
        }
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int {
        min(max(Int(x / width), 0), items.count - 1)
    }

    private func label(_ item: TabItem, highlighted: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: item.symbol).font(.system(size: 19, weight: .semibold)).frame(height: 24)
            Text(item.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(highlighted ? Palette.accent : .white)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { item.action() }
    }
}

/// The bubble of clear glass that follows the finger over the tabs.
struct DragLens: View {
    var body: some View {
        if #available(iOS 26, *) {
            Color.clear
                .glassEffect(.clear.tint(.white.opacity(0.06)).interactive(), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.75))
        } else {
            Capsule().fill(Color.white.opacity(0.18)).overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
    }
}

extension LibrarySection {
    var tabSymbol: String { switch self { case .movies: return "movieclapper"; case .series: return "play.tv"; case .videos: return "play" } }
}

/// The header shared by Inicio, Biblioteca and Buscar.
struct ScreenHeader<Trailing: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Brand()
                if let title { Text(title).font(.system(size: 40, weight: .bold)).padding(.top, 6) }
                if let subtitle { Text(subtitle).font(.title3).foregroundStyle(Palette.secondaryText) }
            }
            Spacer()
            HStack(spacing: 12, content: trailing).padding(.bottom, title == nil ? 0 : 8)
        }
        .padding(.horizontal, 20)
    }
}
