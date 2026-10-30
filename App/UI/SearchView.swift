import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @FocusState private var focused: Bool
    @AppStorage("recentSearches") private var recentText = ""
    private var recent: [String] { recentText.split(separator: "\n").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Buscar", subtitle: nil) { EmptyView() }.padding(.top, 8)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondaryText)
                    TextField("Películas, series, actores, artistas…", text: $query)
                        .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { remember(query) }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondaryText) }
                            .accessibilityLabel("Borrar búsqueda")
                    }
                }
                .padding(.horizontal, 18).frame(height: 50)
                .liquidBar()
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 20)

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !recent.isEmpty { recentSection }
                    genreGrid
                    PosterRow(title: "Recomendado para ti", ids: store.recommended)
                } else {
                    let movies = store.library.movies.map(\.id).filter(matches)
                    let shows = store.library.shows.map(\.id).filter(matches)
                    let clips = store.library.videos.filter { ($0.title + " " + $0.artist + " " + $0.genre).matches(query) }
                    if movies.isEmpty && shows.isEmpty && clips.isEmpty {
                        Text("Sin resultados para «\(query)».").foregroundStyle(Palette.secondaryText).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if !movies.isEmpty { results("Películas", movies) }
                    if !shows.isEmpty { results("Series", shows) }
                    if !clips.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Videos").font(.title3.weight(.semibold))
                            ClipGrid(clips: clips)
                        }.padding(.horizontal, 20)
                    }
                }
            }.padding(.bottom, BarInset.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)

    }


    private func remember(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        recentText = ([value] + recent.filter { $0.searchKey != value.searchKey }).prefix(8).joined(separator: "\n")
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recientes").font(.title3.weight(.semibold))
                Spacer()
                Button("Borrar") { recentText = "" }.font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recent, id: \.self) { item in
                        Button { query = item } label: {
                            Label(item, systemImage: "clock.arrow.circlepath").font(.subheadline)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Palette.surface, in: Capsule()).overlay(Capsule().stroke(Palette.stroke))
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollClipDisabled()
        }.padding(.horizontal, 20)
    }

    /// Genres from TMDB, each shown with the backdrop of its best-rated title.
    private var genreGrid: some View {
        let infos = (store.library.movies.map(\.id) + store.library.shows.map(\.id)).compactMap { id in store.metadata[id].map { (id, $0) } }
        let genres = Array(Catalog.genres(infos.map(\.1)).prefix(8))
        return Group {
            if !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Explorar por género").font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(genres, id: \.self) { genre in
                            let cover = Self.cover(for: genre, in: infos.map { $0.1 })
                            Button { query = genre; remember(genre) } label: {
                                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                                    .overlay { Artwork(source: cover?.wideThumb, title: "") }
                                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom) }
                                    .overlay(alignment: .bottomLeading) { Text(genre).font(.headline).padding(12) }
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    private static func cover(for genre: String, in infos: [MediaInfo]) -> MediaInfo? {
        let candidates = infos.filter { $0.genres.contains(genre) && $0.backdropPath != nil }
        return candidates.max { ($0.rating ?? 0) < ($1.rating ?? 0) }
    }

    /// Matches the TMDB and file titles, the original title, genres and the cast.
    private func matches(_ id: String) -> Bool {
        let info = store.metadata[id]
        let names = [store.card(id)?.title ?? "", store.movie(id)?.title ?? store.show(id)?.title ?? "", info?.originalTitle ?? ""]
            + (info?.genres ?? []) + (info?.cast.prefix(10).map(\.name) ?? []) + (info?.directors ?? [])
        return names.joined(separator: " ").matches(query)
    }

    private func results(_ title: String, _ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            TitleGrid(ids: ids)
        }.padding(.horizontal, 20)
    }
}
