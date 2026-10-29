import SwiftUI
import AVKit

/// Artwork from TMDB or the NAS, with a titled placeholder while it loads or when there is none.
struct Artwork: View {
    @EnvironmentObject var store: AppStore
    var source: ImageSource?
    var title: String = ""
    var maxPixels: CGFloat = 600
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.24), Color(red: 0.06, green: 0.07, blue: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if !title.isEmpty {
                    Text(title.uppercased()).font(.system(size: 13, weight: .medium, design: .serif)).kerning(2)
                        .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75)).padding(10)
                }
            }
        }
        .clipped()
        .task(id: source) {
            guard let source else { image = nil; return }
            if let cached = ImageLoader.shared.cached(source, maxPixels: maxPixels) { image = cached; return }
            image = nil
            let loaded = await ImageLoader.shared.image(source, account: store.account, maxPixels: maxPixels)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = loaded } }
        }
    }
}

extension MediaInfo {
    var poster: ImageSource? { posterPath.map { ImageSource.tmdb($0, size: "w500") } }
    var backdrop: ImageSource? { backdropPath.map { ImageSource.tmdb($0, size: "w1280") } }
    var wideThumb: ImageSource? { backdropPath.map { ImageSource.tmdb($0, size: "w780") } }
}

struct SectionHeader: View {
    var title: String
    var action: (() -> Void)?
    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) { Text("Ver todo"); Image(systemName: "chevron.right") }.font(.subheadline).foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }
}

struct ProgressBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Palette.accent).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }.frame(height: 3).accessibilityLabel("Visto el \(Int(fraction * 100)) %")
    }
}

/// Genre chips like the sketches: "Todas" first, the selected one filled in white.
struct ChipBar: View {
    var all: String
    var options: [String]
    @Binding var selection: String?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip(all, selected: selection == nil) { selection = nil }
                ForEach(options, id: \.self) { option in chip(option, selected: selection == option) { selection = option } }
            }.padding(.horizontal, 20)
        }
    }
    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(text).font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .foregroundStyle(selected ? Color.black : .white)
                .background(selected ? Color.white.opacity(0.92) : Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(Palette.stroke))
        }.buttonStyle(.plain)
    }
}

/// A poster with its title and one line of details underneath, plus the ⋮ menu.
struct PosterCard<MenuItems: View>: View {
    var source: ImageSource?
    var title: String
    var detail: String
    var progress: WatchProgress?
    var aspect: CGFloat = 2.0 / 3.0
    @ViewBuilder var menu: () -> MenuItems

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(aspect, contentMode: .fit)
                .overlay { Artwork(source: source, title: title) }
                .overlay(alignment: .bottom) {
                    if let progress, progress.resumable { ProgressBar(fraction: progress.fraction).padding(6) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke))
            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu(content: menu) {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.subheadline)
                        .frame(width: 22, height: 30).contentShape(Rectangle())
                }.foregroundStyle(Palette.secondaryText).accessibilityLabel("Más opciones")
            }
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = UIColor(Palette.accent)
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

func dot(_ parts: [String?]) -> String { parts.compactMap { $0?.nonEmpty }.joined(separator: " • ") }

/// Everything a poster or carousel needs for one movie or show.
struct TitleCard: Identifiable {
    var id: String
    var route: Route
    var title: String
    var detail: String
    var poster: ImageSource?
    var backdrop: ImageSource?
    var info: MediaInfo?
}

extension AppStore {
    func card(_ id: String) -> TitleCard? {
        if let movie = movie(id) {
            let info = metadata[id]
            return TitleCard(id: id, route: .movie(id), title: title(movie), detail: dot([year(movie).map(String.init), info?.genres.first]),
                             poster: info?.poster, backdrop: info?.backdrop, info: info)
        }
        if let show = show(id) {
            let info = metadata[id]
            return TitleCard(id: id, route: .show(id), title: title(show), detail: dot([countText(show.seasonCount, "temporada", "temporadas"), info?.genres.first]),
                             poster: info?.poster, backdrop: info?.backdrop, info: info)
        }
        return nil
    }

    /// Image for a "Continuar viendo" card: the episode still, otherwise the title's backdrop.
    func thumbnail(forPlayback id: String) -> ImageSource? {
        if let info = metadata[id] { return info.wideThumb }
        if let show = show(containing: id), let info = metadata[show.id] {
            if let episode = show.seasons.flatMap(\.episodes).first(where: { $0.id == id }),
               let still = info.episode(season: episode.season, number: episode.number)?.stillPath { return .tmdb(still, size: "w780") }
            return info.wideThumb
        }
        return library.videos.first { $0.id == id }?.thumbnail.map { ImageSource.nas($0) }
    }
}

/// The ⋮ menu shared by posters everywhere.
struct TitleMenu: View {
    @EnvironmentObject var store: AppStore
    var id: String
    var body: some View {
        if let request = store.movie(id).map({ store.request(movie: $0) }) ?? store.show(id).flatMap({ show in store.nextEpisode(show).map { store.request(episode: $0, show: show) } }) {
            Button("Reproducir", systemImage: "play.fill") { store.play(request) }
        }
        Button(store.watchlist.contains(id) ? "Quitar de Mi lista" : "Añadir a Mi lista", systemImage: store.watchlist.contains(id) ? "minus.circle" : "plus.circle") { store.toggleWatchlist(id) }
        if store.movie(id) != nil {
            if store.progress[id]?.finished == true {
                Button("Marcar como no vista", systemImage: "eye.slash") { store.clearProgress(id) }
            } else {
                Button("Marcar como vista", systemImage: "checkmark.circle") { store.markWatched(id) }
            }
        }
    }
}

struct PosterRow: View {
    @EnvironmentObject var store: AppStore
    var title: String
    var ids: [String]
    var body: some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: Route.list(title: title, ids: ids)) { SectionHeader(title: title, action: {}).allowsHitTesting(false) }
                    .buttonStyle(.plain).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(ids, id: \.self) { id in
                            if let card = store.card(id) {
                                NavigationLink(value: card.route) {
                                    PosterCard(source: card.poster, title: card.title, detail: card.detail, progress: store.progress[id]) { TitleMenu(id: id) }
                                        .frame(width: 128)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }
}
