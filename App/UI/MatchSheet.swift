import SwiftUI

/// "Corregir información": pick the right TMDB entry when the automatic match was wrong.
struct MatchSheet: View {
    @EnvironmentObject var store: AppStore
    var id: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [TMDBCandidate] = []
    @State private var searching = false
    @State private var applying: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Título", text: $query).autocorrectionDisabled().submitLabel(.search).onSubmit(search)
                        if searching { ProgressView() } else { Button("Buscar", action: search).disabled(query.isEmpty) }
                    }
                } footer: { Text("Elige el resultado correcto. También puedes renombrar el archivo o la carpeta en el NAS como Título (Año).") }
                ForEach(results) { candidate in
                    Button { apply(candidate) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Color.clear.frame(width: 60, height: 90)
                                .overlay { Artwork(source: candidate.posterPath.map { ImageSource.tmdb($0, size: "w185") }, title: candidate.title, maxPixels: 200) }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title).font(.headline)
                                Text(dot([candidate.year.map(String.init), candidate.originalTitle.flatMap { $0 == candidate.title ? nil : $0 }]))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(candidate.overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer(minLength: 0)
                            if applying == candidate.id { ProgressView() }
                            else if store.metadata[id]?.tmdbID == candidate.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(applying != nil)
                }
            }
            .navigationTitle("Corregir información")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .onAppear {
                query = store.movie(id)?.title ?? store.show(id)?.title ?? ""
                search()
            }
        }
    }

    private func search() {
        guard !query.isEmpty else { return }
        searching = true
        Task {
            results = await store.searchTMDB(for: id, query: query)
            searching = false
        }
    }

    private func apply(_ candidate: TMDBCandidate) {
        applying = candidate.id
        Task {
            let done = await store.applyMatch(candidate, to: id)
            applying = nil
            if done { dismiss() }
        }
    }
}
