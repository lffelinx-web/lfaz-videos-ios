import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    var openSettings: () -> Void
    var openSearch: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if store.featured.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        header.padding(.top, 8)
                        SetupCard(openSettings: openSettings).padding(.horizontal, 20)
                    }
                } else {
                    FeaturedCarousel(ids: store.featured)
                        .overlay(alignment: .top) { header.padding(.top, 54) }
                }
                ContinueWatchingRow()
                if !store.watchlist.isEmpty { PosterRow(title: "Mi lista", ids: store.watchlist.filter { store.card($0) != nil }.sorted()) }
                PosterRow(title: "Recomendado para ti", ids: store.recommended)
                PosterRow(title: "Agregados recientemente", ids: store.recentlyAdded)
            }
            .padding(.bottom, 110)
        }
        .ignoresSafeArea(edges: store.featured.isEmpty ? [] : .top)
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { store.synchronize() }
    }

    private var header: some View {
        ScreenHeader(title: nil, subtitle: nil) {
            RoundIconButton(systemImage: "magnifyingglass", label: "Buscar", action: openSearch)
            Button(action: openSettings) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).symbolRenderingMode(.hierarchical)
                    .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke))
            }.buttonStyle(.plain).accessibilityLabel("Ajustes")
        }
    }
}

/// Shown until there is a NAS, a scanned library and TMDB artwork to feature.
struct SetupCard: View {
    @EnvironmentObject var store: AppStore
    var openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.account == nil ? "Conecta tu NAS" : !store.hasTMDB ? "Añade carátulas de TMDB" : store.library.isEmpty ? "Actualiza tu biblioteca" : "Preparando carátulas…")
                .font(.title3.weight(.semibold))
            Text(store.account == nil ? "Configura la dirección de tu Synology para ver tus películas, series y videos."
                 : !store.hasTMDB ? "Pega tu clave de TMDB en Ajustes para ver portadas, sinopsis y reparto."
                 : store.enrichStatus ?? store.status)
                .font(.subheadline).foregroundStyle(Palette.secondaryText)
            if store.account == nil || !store.hasTMDB {
                Button("Abrir Ajustes", action: openSettings).buttonStyle(.borderedProminent).padding(.top, 4)
            } else if store.library.isEmpty {
                Button { store.synchronize() } label: { Text(store.busy ? "Actualizando…" : "Actualizar biblioteca") }.buttonStyle(.borderedProminent).disabled(store.busy)
            }
        }.card()
    }
}

struct FeaturedCarousel: View {
    @EnvironmentObject var store: AppStore
    var ids: [String]
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let card = store.card(id) { slide(card).tag(index) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 600)
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                ForEach(ids.indices, id: \.self) { index in
                    Circle().fill(index == page ? Color.white : Color.white.opacity(0.35)).frame(width: 7, height: 7)
                }
            }.padding(.bottom, 12)
        }
    }

    private func slide(_ card: TitleCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(source: card.backdrop, maxPixels: 1600).frame(height: 600).frame(maxWidth: .infinity).clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.45), .init(color: Palette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text("DESTACADA").font(.caption.weight(.medium)).kerning(3).foregroundStyle(Palette.secondaryText)
                Text(card.title.uppercased()).font(.system(size: 30, weight: .regular, design: .serif)).kerning(6)
                    .lineLimit(2).minimumScaleFactor(0.6)
                Text(dot([card.info?.year.map(String.init), card.info?.genres.first, card.info?.kind == .movie ? Catalog.runtimeText(card.info?.runtime) : store.show(card.id).map { countText($0.seasonCount, "temporada", "temporadas") }]))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                if let overview = card.info?.overview.nonEmpty {
                    Text(overview).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(3).frame(maxWidth: 330, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button { playDefault(card.id) } label: {
                        Label("Reproducir", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                    NavigationLink(value: card.route) {
                        Text("Más información").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke))
                    }.buttonStyle(.plain)
                }.padding(.top, 6)
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
    }

    private func playDefault(_ id: String) {
        if let movie = store.movie(id) { store.play(store.request(movie: movie)) }
        else if let show = store.show(id), let episode = store.nextEpisode(show) { store.play(store.request(episode: episode, show: show)) }
    }
}

struct ContinueWatchingRow: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        let items = store.continueWatching
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Continuar viendo").padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items, id: \.request.id) { item in card(item.request, item.progress) }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }

    private func card(_ request: PlaybackRequest, _ progress: WatchProgress) -> some View {
        let show = store.show(containing: request.id)
        let title = show.map { store.title($0) } ?? store.movie(request.id).map { store.title($0) } ?? request.title
        let episode = show.flatMap { show in show.seasons.flatMap(\.episodes).first { $0.id == request.id } }
        return VStack(alignment: .leading, spacing: 6) {
            Button { store.play(request) } label: {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { Artwork(source: store.thumbnail(forPlayback: request.id), title: title) }
                    .overlay { if store.opening == request.id { ProgressView().controlSize(.large) } }
                    .overlay(alignment: .bottom) { ProgressBar(fraction: progress.fraction).padding(8) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(dot([episode.map { "T\($0.season) · E\($0.number)" }, remainingText(progress.remaining)])).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Reproducir", systemImage: "play.fill") { store.play(request) }
                    if let show { NavigationLink(value: Route.show(show.id)) { Label("Ver episodios", systemImage: "list.bullet") } }
                    else if store.movie(request.id) != nil { NavigationLink(value: Route.movie(request.id)) { Label("Más información", systemImage: "info.circle") } }
                    Button("Quitar de Continuar viendo", systemImage: "xmark.circle") { store.clearProgress(request.id) }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 22, height: 30).contentShape(Rectangle())
                }.foregroundStyle(Palette.secondaryText)
            }
        }.frame(width: 240)
    }
}
