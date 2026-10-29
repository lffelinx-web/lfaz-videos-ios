import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Buscar", subtitle: nil) { EmptyView() }.padding(.top, 8)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondaryText)
                    TextField("Películas, series, actores, artistas…", text: $query)
                        .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondaryText) }
                            .accessibilityLabel("Borrar búsqueda")
                    }
                }
                .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.stroke))
                .padding(.horizontal, 20)

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
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
            }.padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = query.isEmpty }
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
