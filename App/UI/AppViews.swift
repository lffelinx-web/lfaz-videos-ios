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

/// The floating bar has two faces: Inicio · Biblioteca · Buscar, and inside Biblioteca
/// the grid button plus Películas · Series · Videos.
enum BarMode: Equatable {
    enum Main: Equatable { case home, search }
    case main(Main)
    case library(LibrarySection)
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var mode = BarMode.main(.home)
    @State private var path = NavigationPath()
    @State private var settings = false

    var body: some View {
        NavigationStack(path: $path) {
            screen
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .movie(let id): MovieDetailView(id: id)
                    case .show(let id): ShowDetailView(id: id)
                    case .list(let title, let ids): TitleGridView(title: title, ids: ids)
                    }
                }
        }
        .overlay(alignment: .bottom) {
            if path.isEmpty {
                // Sits low, over the home indicator area, like the system tab bar.
                FloatingBar(mode: $mode).padding(.horizontal, 16).offset(y: 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: path.isEmpty)
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
        .onChange(of: mode) { _, _ in path = NavigationPath() }
    }

    @ViewBuilder private var screen: some View {
        switch mode {
        case .main(.home): HomeView(openSettings: { settings = true })
        case .main(.search): SearchView()
        case .library(let section): LibraryView(section: section, openSearch: { withAnimation(.snappy) { mode = .main(.search) } })
        }
    }
}

struct FloatingBar: View {
    @Binding var mode: BarMode
    @Namespace private var namespace
    private let spring = Animation.bouncy(duration: 0.45, extraBounce: 0.1)

    var body: some View {
        LiquidContainer(spacing: 6) {
            HStack(spacing: 2) {
                switch mode {
                case .main(let tab):
                    item("Inicio", "house.fill", selected: tab == .home) { mode = .main(.home) }
                        .matchedGeometryEffect(id: "anchor", in: namespace, isSource: true)
                    Group {
                        item("Biblioteca", "books.vertical", selected: false) { mode = .library(.movies) }
                        item("Buscar", "magnifyingglass", selected: tab == .search) { mode = .main(.search) }
                    }.transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading)), removal: .opacity))
                case .library:
                    Button { withAnimation(spring) { mode = .main(.home) } } label: {
                        Image(systemName: "square.grid.2x2.fill").font(.system(size: 18, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Volver al menú principal")
                    .matchedGeometryEffect(id: "anchor", in: namespace, isSource: true)
                    ForEach(LibrarySection.allCases) { section in
                        item(section.title, section.tabSymbol, selected: mode == .library(section)) { mode = .library(section) }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.6, anchor: .leading)),
                                            removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading))))
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity)
            .liquidBar()
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private func item(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(spring) { action() } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Palette.accent : .white)
            .padding(.horizontal, 8).frame(height: 48).frame(maxWidth: .infinity)
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
