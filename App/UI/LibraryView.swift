import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Agregadas recientemente", title = "Título", year = "Año", rating = "Valoración"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    var section: LibrarySection
    var openSearch: () -> Void
    @State private var genre: String?
    @State private var sort = LibrarySort.recent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: section.title, subtitle: section == .videos ? "Videoclips musicales" : nil) {
                    RoundIconButton(systemImage: "magnifyingglass", label: "Buscar", action: openSearch)
                    Menu {
                        Picker("Ordenar", selection: $sort) { ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) } }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 18, weight: .medium))
                            .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke))
                    }.accessibilityLabel("Ordenar")
                }
                .padding(.top, 8)
                ChipBar(all: "Todas", options: genres, selection: $genre)
                content.padding(.horizontal, 20)
            }
            .padding(.bottom, BarInset.bottom)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: section) { _, _ in genre = nil }
        .refreshable { store.synchronize() }
    }

    private var genres: [String] {
        switch section {
        case .movies: return Catalog.genres(store.library.movies.map { store.metadata[$0.id] })
        case .series: return Catalog.genres(store.library.shows.map { store.metadata[$0.id] })
        case .videos: return Array(Set(store.library.videos.map(\.genre))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .movies, .series:
            let ids = sorted(section == .movies ? store.library.movies.map(\.id) : store.library.shows.map(\.id))
            if ids.isEmpty { empty } else { TitleGrid(ids: ids) }
        case .videos:
            let clips = store.library.videos.filter { genre == nil || $0.genre == genre }
            if clips.isEmpty { empty } else { ClipGrid(clips: sortedClips(clips)) }
        }
    }

    private func sorted(_ ids: [String]) -> [String] {
        let filtered = ids.filter { genre == nil || store.metadata[$0]?.genres.contains(genre!) == true }
        func name(_ id: String) -> String { store.card(id)?.title ?? "" }
        switch sort {
        case .recent: return filtered.sorted { (store.library.addedAt[$0] ?? .distantPast) > (store.library.addedAt[$1] ?? .distantPast) }
        case .title: return filtered.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .year: return filtered.sorted { (store.metadata[$0]?.year ?? store.movie($0)?.year ?? 0) > (store.metadata[$1]?.year ?? store.movie($1)?.year ?? 0) }
        case .rating: return filtered.sorted { (store.metadata[$0]?.rating ?? 0) > (store.metadata[$1]?.rating ?? 0) }
        }
    }

    private func sortedClips(_ clips: [MusicVideo]) -> [MusicVideo] {
        switch sort {
        case .recent: return clips.sorted { (store.library.addedAt[$0.id] ?? .distantPast) > (store.library.addedAt[$1.id] ?? .distantPast) }
        case .title: return clips.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year, .rating: return clips.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: section.symbol).font(.largeTitle).foregroundStyle(Palette.accent)
            Text(genre == nil ? "No hay \(section.title.lowercased()) todavía" : "Nada en \(genre!)").font(.headline)
            Text(genre == nil ? "Añádelos a la carpeta \(section.title) del NAS y desliza hacia abajo para actualizar." : "Prueba con otra categoría.")
                .font(.subheadline).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

/// Three columns of posters, as in the Películas and Series sketches.
struct TitleGrid: View {
    @EnvironmentObject var store: AppStore
    var ids: [String]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), spacing: 20) {
            ForEach(ids, id: \.self) { id in
                if let card = store.card(id) {
                    NavigationLink(value: card.route) {
                        PosterCard(source: card.poster, title: card.title, detail: card.detail, progress: store.progress[id]) { TitleMenu(id: id) }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// Two columns of 16:9 thumbnails with the duration, as in the Videos sketch.
struct ClipGrid: View {
    @EnvironmentObject var store: AppStore
    var clips: [MusicVideo]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2), spacing: 18) {
            ForEach(clips) { clip in
                VStack(alignment: .leading, spacing: 6) {
                    Button { store.play(store.request(clip: clip)) } label: {
                        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { Artwork(source: clip.thumbnail.map { ImageSource.nas($0) } ?? .frame(clip.file), title: clip.artist) }
                            .overlay { if store.opening == clip.id { ProgressView() } }
                            .overlay(alignment: .bottomTrailing) {
                                if let duration = store.duration(of: clip), duration > 1 {
                                    Text(clockText(duration)).font(.caption2.weight(.semibold).monospacedDigit())
                                        .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).padding(6)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke))
                    }.buttonStyle(.plain)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(clip.artist).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("Reproducir", systemImage: "play.fill") { store.play(store.request(clip: clip)) }
                            Button(store.watchlist.contains(clip.id) ? "Quitar de Mi lista" : "Añadir a Mi lista", systemImage: "plus.circle") { store.toggleWatchlist(clip.id) }
                        } label: {
                            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 22, height: 30).contentShape(Rectangle())
                        }.foregroundStyle(Palette.secondaryText).accessibilityLabel("Más opciones")
                    }
                }
                .task(id: clip.id) { await store.probeDuration(clip) }
            }
        }
    }
}

/// "Ver todo" from a row on Inicio.
struct TitleGridView: View {
    var title: String
    var ids: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    RoundIconButton(systemImage: "chevron.left", label: "Atrás") { dismiss() }
                    Text(title).font(.title2.weight(.bold)).padding(.leading, 6)
                    Spacer()
                }.padding(.horizontal, 20)
                TitleGrid(ids: ids).padding(.horizontal, 20)
            }.padding(.vertical, 8).padding(.bottom, 40)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }
}
