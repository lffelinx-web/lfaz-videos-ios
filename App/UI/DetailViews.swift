import SwiftUI

// MARK: Shared pieces of the movie and series sheets

/// Backdrop, back/AirPlay/⋯ buttons, spaced title, details, quality badges and the action row.
struct DetailHeader<Actions: View>: View {
    @EnvironmentObject var store: AppStore
    var id: String
    var title: String
    var meta: String
    var badges: [String]
    var info: MediaInfo?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dismiss) private var dismiss
    @State private var showMatch = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(source: info?.backdrop ?? info?.poster, title: title, maxPixels: 1600)
                .frame(height: 540).frame(maxWidth: .infinity).clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.38), .init(color: Palette.background.opacity(0.75), location: 0.68),
                                   .init(color: Palette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                // Long titles get a smaller size and tighter spacing instead of being squeezed.
                let long = title.count > 26
                let medium = title.count > 14
                Text(title.uppercased())
                    .font(.system(size: long ? 22 : medium ? 27 : 34, weight: .regular, design: .serif))
                    .kerning(long ? 2.5 : medium ? 4 : 7)
                    .lineLimit(3).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                if let original = info?.originalTitle, original.searchKey != title.searchKey {
                    Text(original.uppercased()).font(.caption2.weight(.medium)).kerning(3)
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Text(meta).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    ForEach(badges.prefix(3), id: \.self) { QualityBadge(text: $0) }
                }
                actions().padding(.top, 6)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 540, alignment: .bottom)
        .sheet(isPresented: $showMatch) { MatchSheet(id: id) }
        .overlay(alignment: .top) {
            HStack {
                RoundIconButton(systemImage: "chevron.left", label: "Atrás") { dismiss() }
                Spacer()
                RoutePicker().frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke))
                    .accessibilityLabel("AirPlay")
                Menu {
                    TitleMenu(id: id)
                    Button("Corregir información", systemImage: "wand.and.stars") { showMatch = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                        .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke))
                }.accessibilityLabel("Más opciones")
            }
            .padding(.horizontal, 20).padding(.top, 54)
        }
    }
}

struct ActionRow: View {
    @EnvironmentObject var store: AppStore
    var id: String
    var playTitle: String
    var playing: Bool
    /// What the download button saves: the movie, or the next episode of a series.
    var downloadID: String? = nil
    var play: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                HStack(spacing: 6) {
                    if playing { ProgressView().tint(.black) } else { Image(systemName: "play.fill").font(.subheadline) }
                    Text(playTitle).lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 44)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 22)).foregroundStyle(.black)
            }.buttonStyle(.plain)
            Button { store.toggleWatchlist(id) } label: {
                Label(store.watchlist.contains(id) ? "En mi lista" : "Añadir", systemImage: store.watchlist.contains(id) ? "checkmark" : "plus")
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 44)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.stroke))
            }.buttonStyle(.plain)
            DownloadButton(id: downloadID ?? id, size: 44)
        }
    }
}

/// Download, progress ring with stop, or a check mark with "Eliminar descarga".
struct DownloadButton: View {
    @EnvironmentObject var store: AppStore
    var id: String
    var size: CGFloat = 50
    @State private var confirmRemove = false

    var body: some View {
        Group {
            if let progress = store.downloadProgress[id] {
                Button { store.cancelDownload(id) } label: {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.02, progress)).stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill").font(.system(size: size * 0.26))
                    }.padding(size * 0.12)
                }.accessibilityLabel("Detener descarga, \(Int(progress * 100)) %")
            } else if store.downloadedIDs.contains(id) {
                Button { confirmRemove = true } label: { Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.42)).foregroundStyle(Palette.accent) }
                    .accessibilityLabel("Descargado")
                    .confirmationDialog("Disponible sin conexión", isPresented: $confirmRemove) {
                        Button("Eliminar descarga", role: .destructive) { store.removeDownload(id) }
                    }
            } else {
                Button { store.download(id) } label: { Image(systemName: "arrow.down.to.line").font(.system(size: size * 0.34, weight: .semibold)) }
                    .accessibilityLabel("Descargar")
            }
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.12), in: Circle()).overlay(Circle().stroke(Palette.stroke))
    }
}
struct DetailTabs<Tab: Hashable>: View {
    var tabs: [(Tab, String)]
    @Binding var selection: Tab
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.0) { item in
                let tab = item.0
                let title = item.1
                Button { withAnimation(.snappy) { selection = tab } } label: {
                    Text(title).font(.subheadline.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? .white : Palette.secondaryText)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background {
                            if selection == tab {
                                Capsule().fill(Palette.accent.opacity(0.3)).overlay(Capsule().stroke(Palette.accent.opacity(0.8)))
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Palette.surface, in: Capsule()).overlay(Capsule().stroke(Palette.stroke))
    }
}

struct Overview: View {
    var text: String
    @State private var expanded = false
    var body: some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.body).foregroundStyle(.white.opacity(0.88)).lineLimit(expanded ? nil : 3)
                Button { withAnimation { expanded.toggle() } } label: {
                    Label(expanded ? "Leer menos" : "Leer más", systemImage: expanded ? "chevron.up" : "chevron.down").font(.subheadline)
                }.foregroundStyle(Palette.secondaryText)
            }
        }
    }
}

enum ExploreSheet: String, Identifiable { case cast, gallery, similar; var id: String { rawValue } }

/// "Explora …": Reparto, Ambiente and Más como esto.
struct ExploreCards: View {
    var title: String
    var info: MediaInfo?
    var hasRelated: Bool
    @Binding var sheet: ExploreSheet?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explora \(title)").font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if !(info?.cast.isEmpty ?? true) { card("Reparto", "Conoce al elenco y al equipo creativo", "person.2", image: info?.cast.first?.profilePath.map { ImageSource.tmdb($0, size: "w300") }) { sheet = .cast } }
                    if !(info?.backdrops.isEmpty ?? true) { card("Ambiente", "Mundos, escenarios e imágenes", "photo", image: info?.backdrops.dropFirst().first.map { ImageSource.tmdb($0, size: "w780") }) { sheet = .gallery } }
                    if hasRelated { card("Más como esto", "Títulos similares de tu biblioteca", "square.stack.3d.up", image: info?.wideThumb) { sheet = .similar } }
                }
            }.scrollClipDisabled()
        }
    }
    private func card(_ title: String, _ subtitle: String, _ symbol: String, image: ImageSource?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Artwork(source: image).frame(width: 220, height: 110).clipped()
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(subtitle).font(.caption2).foregroundStyle(Palette.secondaryText).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption)
                }.padding(10)
            }
            .frame(width: 220)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.stroke))
        }.buttonStyle(.plain)
    }
}

struct InfoPanel: View {
    var rows: [(symbol: String, label: String, value: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Información").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 16) {
                ForEach(rows.filter { !$0.value.isEmpty }, id: \.label) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.symbol).frame(width: 22).foregroundStyle(Palette.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).font(.caption).foregroundStyle(Palette.secondaryText)
                            Text(row.value).font(.subheadline).lineLimit(3)
                        }
                    }
                }
            }
        }.card()
    }
}

struct ExploreSheetView: View {
    @EnvironmentObject var store: AppStore
    var kind: ExploreSheet
    var info: MediaInfo?
    var related: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                switch kind {
                case .cast:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 18) {
                        ForEach(info?.cast ?? [], id: \.self) { person in
                            VStack(spacing: 6) {
                                Artwork(source: person.profilePath.map { ImageSource.tmdb($0, size: "w300") }, title: person.name).frame(width: 90, height: 90).clipShape(Circle())
                                Text(person.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                                Text(person.role).font(.caption2).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center).lineLimit(2)
                            }
                        }
                    }.padding(20)
                    if let directors = info?.directors, !directors.isEmpty {
                        Text((info?.kind == .tv ? "Creada por " : "Dirigida por ") + directors.joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(Palette.secondaryText).padding(.horizontal, 20)
                    }
                case .gallery:
                    LazyVStack(spacing: 12) {
                        ForEach(info?.backdrops ?? [], id: \.self) { path in
                            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                                .overlay { Artwork(source: .tmdb(path, size: "w1280"), maxPixels: 1400) }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }.padding(20)
                case .similar:
                    TitleGrid(ids: related).padding(20)
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(kind == .cast ? "Reparto" : kind == .gallery ? "Ambiente" : "Más como esto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .movie(let id): MovieDetailView(id: id)
                case .show(let id): ShowDetailView(id: id)
                case .list(let title, let ids): TitleGridView(title: title, ids: ids)
                }
            }
        }
    }
}

// MARK: Movie

struct MovieDetailView: View {
    @EnvironmentObject var store: AppStore
    var id: String
    enum Tab: Hashable { case watch, universe, details }
    @State private var tab = Tab.watch
    @State private var sheet: ExploreSheet?

    var body: some View {
        if let movie = store.movie(id) {
            let info = store.metadata[id]
            let title = store.title(movie)
            let related = store.related(id)
            let progress = store.progress[id]
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DetailHeader(id: id, title: title, meta: dot([store.year(movie).map(String.init), info?.genres.first, Catalog.runtimeText(info?.runtime)]),
                                 badges: movie.tags.isEmpty ? [movie.file.format] : movie.tags, info: info) {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionRow(id: id, playTitle: progress?.resumable == true ? "Continuar" : "Reproducir", playing: store.opening == id) {
                                store.play(store.request(movie: movie))
                            }
                            if let progress, progress.resumable {
                                HStack { ProgressBar(fraction: progress.fraction).frame(width: 120); Text(remainingText(progress.remaining)).font(.caption).foregroundStyle(Palette.secondaryText) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        DetailTabs(tabs: [(Tab.watch, "Ver ahora"), (.universe, "Universo"), (.details, "Detalles")], selection: $tab)
                        switch tab {
                        case .watch:
                            Overview(text: info?.overview ?? "")
                            ExploreCards(title: title, info: info, hasRelated: !related.isEmpty, sheet: $sheet)
                            InfoPanel(rows: infoRows(movie, info))
                            if !related.isEmpty { universeRow(related, info: info) }
                        case .universe:
                            if related.isEmpty {
                                Text("Aún no hay títulos relacionados en tu biblioteca.").foregroundStyle(Palette.secondaryText)
                            } else {
                                if let collection = info?.collectionName { Text(collection).font(.title3.weight(.semibold)) }
                                TitleGrid(ids: related)
                            }
                        case .details:
                            if let tagline = info?.tagline { Text("“\(tagline)”").font(.headline).italic() }
                            Text(info?.overview.nonEmpty ?? "Sin sinopsis.").foregroundStyle(.white.opacity(0.88))
                            InfoPanel(rows: infoRows(movie, info) + fileRows(movie.file))
                        }
                    }.padding(.horizontal, 20)
                }.padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .background(Palette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sheet) { ExploreSheetView(kind: $0, info: info, related: related) }
        } else {
            Text("Esta película ya no está en la biblioteca.").foregroundStyle(Palette.secondaryText)
        }
    }

    private func universeRow(_ ids: [String], info: MediaInfo?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: info?.collectionName != nil ? "Dentro del universo" : "Más como esto") { tab = .universe }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(ids, id: \.self) { other in
                        if let card = store.card(other) {
                            NavigationLink(value: card.route) {
                                Color.clear.aspectRatio(2 / 3, contentMode: .fit).frame(width: 120)
                                    .overlay { Artwork(source: card.poster, title: card.title) }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.scrollClipDisabled()
        }
    }

    private func infoRows(_ movie: Movie, _ info: MediaInfo?) -> [(symbol: String, label: String, value: String)] {
        [("movieclapper", "Dirección", info?.directors.joined(separator: ", ") ?? ""),
         ("theatermasks", "Género", info?.genres.prefix(2).joined(separator: ", ") ?? ""),
         ("person.2", "Reparto", info?.cast.prefix(4).map(\.name).joined(separator: ", ") ?? ""),
         ("calendar", "Año", store.year(movie).map(String.init) ?? ""),
         ("globe", "Idioma", info?.languages.prefix(3).map(Catalog.languageName).joined(separator: ", ") ?? ""),
         ("clock", "Duración", Catalog.runtimeText(info?.runtime) ?? ""),
         ("star", "Valoración", info?.rating.flatMap { $0 > 0 ? String(format: "%.1f / 10", $0) : nil } ?? ""),
         ("film", "Formato", ([movie.file.format] + movie.tags).joined(separator: " · "))]
    }
}

func fileRows(_ file: VideoFile) -> [(symbol: String, label: String, value: String)] {
    [("doc", "Archivo", file.url.lastPathComponent),
     ("internaldrive", "Tamaño", file.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")]
}

// MARK: Series

struct ShowDetailView: View {
    @EnvironmentObject var store: AppStore
    var id: String
    enum Tab: Hashable { case episodes, universe, details }
    @State private var tab = Tab.episodes
    @State private var season: Int?
    @State private var sheet: ExploreSheet?

    var body: some View {
        if let show = store.show(id) {
            let info = store.metadata[id]
            let title = store.title(show)
            let related = store.related(id)
            let next = store.nextEpisode(show)
            let current = season ?? next?.season ?? show.seasons.first?.number ?? 1
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DetailHeader(id: id, title: title,
                                 meta: dot([store.year(show).map(String.init), info?.genres.first, countText(show.seasonCount, "temporada", "temporadas")]),
                                 badges: Array(Set(show.seasons.flatMap(\.episodes).map(\.file.format))).sorted(), info: info) {
                        VStack(alignment: .leading, spacing: 8) {
                            ActionRow(id: id, playTitle: next.map { (store.progress[$0.id]?.resumable == true ? "Continuar " : "Reproducir ") + "T\($0.season) · E\($0.number)" } ?? "Reproducir",
                                      playing: next.map { store.opening == $0.id } ?? false, downloadID: next?.id) {
                                if let next { store.play(store.request(episode: next, show: show)) }
                            }
                            if let next, let progress = store.progress[next.id], progress.resumable {
                                Text("Quedan \(remainingText(progress.remaining).replacingOccurrences(of: " restantes", with: ""))" + (episodeName(next, info).map { " de «\($0)»" } ?? ""))
                                    .font(.caption).foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        DetailTabs(tabs: [(Tab.episodes, "Episodios"), (.universe, "Universo"), (.details, "Detalles")], selection: $tab)
                        switch tab {
                        case .episodes:
                            seasonPicker(show, current: current)
                            if let episodes = show.seasons.first(where: { $0.number == current })?.episodes {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    ForEach(episodes) { episode in episodeRow(episode, show: show, info: info) }
                                }
                            }
                            ExploreCards(title: title, info: info, hasRelated: !related.isEmpty, sheet: $sheet)
                        case .universe:
                            if related.isEmpty { Text("Aún no hay series relacionadas en tu biblioteca.").foregroundStyle(Palette.secondaryText) }
                            else { TitleGrid(ids: related) }
                        case .details:
                            if let tagline = info?.tagline { Text("“\(tagline)”").font(.headline).italic() }
                            Overview(text: info?.overview ?? "")
                            InfoPanel(rows: [
                                ("person.crop.rectangle", "Creada por", info?.directors.joined(separator: ", ") ?? ""),
                                ("theatermasks", "Género", info?.genres.prefix(2).joined(separator: ", ") ?? ""),
                                ("person.2", "Reparto", info?.cast.prefix(4).map(\.name).joined(separator: ", ") ?? ""),
                                ("calendar", "Estreno", store.year(show).map(String.init) ?? ""),
                                ("globe", "Idioma", info?.languages.prefix(3).map(Catalog.languageName).joined(separator: ", ") ?? ""),
                                ("rectangle.stack", "En tu NAS", countText(show.episodeCount, "episodio", "episodios")),
                                ("star", "Valoración", info?.rating.flatMap { $0 > 0 ? String(format: "%.1f / 10", $0) : nil } ?? "")
                            ])
                        }
                    }.padding(.horizontal, 20)
                }.padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .background(Palette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sheet) { ExploreSheetView(kind: $0, info: info, related: related) }
        } else {
            Text("Esta serie ya no está en la biblioteca.").foregroundStyle(Palette.secondaryText)
        }
    }

    private func episodeName(_ episode: Episode, _ info: MediaInfo?) -> String? {
        info?.episode(season: episode.season, number: episode.number)?.name.nonEmpty ?? episode.title
    }

    /// Season chips scroll on their own row; the episode count sits underneath so it never covers a chip.
    private func seasonPicker(_ show: Show, current: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LiquidChips(items: show.seasons.map { (id: $0.number, title: $0.title) },
                        selection: Binding(get: { current }, set: { season = $0 }))
            Text(countText(show.seasons.first { $0.number == current }?.episodes.count ?? 0, "episodio", "episodios"))
                .font(.caption).foregroundStyle(Palette.secondaryText)
        }
    }

    private func episodeRow(_ episode: Episode, show: Show, info: MediaInfo?) -> some View {
        let tmdb = info?.episode(season: episode.season, number: episode.number)
        let progress = store.progress[episode.id]
        let name = tmdb?.name.nonEmpty ?? episode.title ?? "Episodio \(episode.number)"
        return HStack(alignment: .center, spacing: 8) {
            Button { store.play(store.request(episode: episode, show: show)) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Color.clear.frame(width: 130, height: 74)
                        .overlay { Artwork(source: tmdb?.stillPath.map { ImageSource.tmdb($0, size: "w300") } ?? info?.wideThumb, title: "") }
                        .overlay {
                            if store.opening == episode.id { ProgressView() }
                            else { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if progress?.finished == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).padding(5) }
                        }
                        .overlay(alignment: .bottom) { if let progress, progress.resumable { ProgressBar(fraction: progress.fraction).padding(5) } }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.number > 0 ? "\(episode.number). \(name)" : name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(dot([Catalog.runtimeText(tmdb?.runtime), progress?.resumable == true ? remainingText(progress!.remaining) : progress?.finished == true ? "Visto" : nil, episode.file.format]))
                            .font(.caption).foregroundStyle(progress?.resumable == true ? Palette.accent : Palette.secondaryText)
                        if let overview = tmdb?.overview.nonEmpty {
                            Text(overview).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            DownloadButton(id: episode.id, size: 36)
        }
        .contextMenu {
            if progress?.finished == true { Button("Marcar como no visto", systemImage: "eye.slash") { store.clearProgress(episode.id) } }
            else { Button("Marcar como visto", systemImage: "checkmark.circle") { store.markWatched(episode.id) } }
        }
    }
}
