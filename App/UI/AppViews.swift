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
    private let height: CGFloat = 62

    var body: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if tab.isLibrary {
                    circleButton(label: "Volver al menú principal", action: { select(.home) }) {
                        Image(systemName: "square.grid.2x2.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    }
                    capsule {
                        ForEach(LibrarySection.allCases) { section in
                            item(section.title, section.tabSymbol, selected: tab == .section(section)) { select(.section(section)) }
                        }
                    }
                } else {
                    capsule {
                        item("Inicio", "house.fill", selected: tab == .home) { select(.home) }
                        item("Biblioteca", "books.vertical.fill", selected: false) { select(.section(.movies)) }
                        item("Buscar", "magnifyingglass", selected: tab == .search) { select(.search) }
                    }
                    circleButton(label: "Perfil, Mi lista y Descargas", action: { select(.profile) }) {
                        ProfileAvatar(size: height - 14)
                            .overlay(Circle().stroke(Palette.accent, lineWidth: tab == .profile ? 2.5 : 0).padding(-3))
                    }
                    .accessibilityAddTraits(tab == .profile ? .isSelected : [])
                }
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .padding(4)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .glassPiece(Capsule(), id: "capsule", in: namespace)
    }

    private func circleButton<Label: View>(label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Label) -> some View {
        Button(action: action) {
            content().frame(width: height, height: height).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassPiece(Circle(), id: "circle", in: namespace)
        .accessibilityLabel(label)
    }

    private func item(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).frame(height: 24)
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Palette.accent : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidSelection(selected, in: namespace)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
