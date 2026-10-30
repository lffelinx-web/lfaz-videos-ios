import Foundation

private struct SavedMetadata: Codable {
    var items: [String: MediaInfo] = [:]
    var unmatched: Set<String> = []
    /// Bumped when matching improves, so earlier guesses are looked up again.
    var version: Int? = SavedMetadata.currentVersion
    static let currentVersion = 2
}

/// TMDB metadata, "Mi lista" and the lookups the screens use.
extension AppStore {
    func loadExtras() {
        var saved = Files.load(metadataName, as: SavedMetadata.self) ?? SavedMetadata()
        if saved.version != SavedMetadata.currentVersion { saved = SavedMetadata() }
        metadata = saved.items; unmatched = saved.unmatched
        watchlist = Files.load(watchlistName, as: Set<String>.self) ?? []
    }

    private func saveMetadata() { try? Files.save(SavedMetadata(items: metadata, unmatched: unmatched), name: metadataName) }

    // MARK: TMDB

    func setTMDB(token: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { error = "Pega la clave de TMDB."; return false }
        do {
            try await TMDBClient(token: token).verify()
            try TMDBCredential.save(token)
            hasTMDB = true
            enrichMetadata()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func removeTMDB() { TMDBCredential.clear(); hasTMDB = false; enrichTask?.cancel(); enrichStatus = nil }

    /// Looks up every movie and show without metadata. `refresh` searches everything again.
    func enrichMetadata(refresh: Bool = false) {
        guard let token = TMDBCredential.load(), account != nil else { return }
        if refresh { metadata = [:]; unmatched = [] }
        enrichTask?.cancel()
        let client = TMDBClient(token: token)
        let movies = library.movies.filter { metadata[$0.id] == nil && !unmatched.contains($0.id) }
        let shows = library.shows.filter { metadata[$0.id] == nil && !unmatched.contains($0.id) }
        let total = movies.count + shows.count
        guard total > 0 else { return }
        enrichTask = Task {
            var done = 0
            defer { enrichStatus = nil; saveMetadata() }
            for movie in movies {
                if Task.isCancelled { return }
                enrichStatus = "Carátulas: \(done + 1) de \(total)"
                do {
                    if let info = try await client.movie(title: movie.title, year: movie.year) { metadata[movie.id] = info } else { unmatched.insert(movie.id) }
                } catch { if handle(error) { return } }
                done += 1
                if done % 10 == 0 { saveMetadata() }
            }
            for show in shows {
                if Task.isCancelled { return }
                enrichStatus = "Carátulas: \(done + 1) de \(total)"
                do {
                    if var info = try await client.show(title: show.title, year: show.year) {
                        info.seasons = try await client.seasons(show.seasons.map(\.number), of: info)
                        metadata[show.id] = info
                    } else { unmatched.insert(show.id) }
                } catch { if handle(error) { return } }
                done += 1
                if done % 5 == 0 { saveMetadata() }
            }
        }
    }

    /// Stops on errors that will repeat for every title (bad key, no internet).
    private func handle(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let video = error as? VideoError, video.localizedDescription.contains("clave") { self.error = video.localizedDescription; return true }
        if (error as? URLError)?.code == .notConnectedToInternet { return true }
        return false
    }


    // MARK: Manual matches

    /// Search used by "Corregir información", in the title's own kind.
    func searchTMDB(for id: String, query: String) async -> [TMDBCandidate] {
        guard let token = TMDBCredential.load() else { error = "Añade la clave de TMDB en Ajustes."; return [] }
        do { return try await TMDBClient(token: token).search(show(id) != nil ? .tv : .movie, query: query) }
        catch { self.error = error.localizedDescription; return [] }
    }

    func applyMatch(_ candidate: TMDBCandidate, to id: String) async -> Bool {
        guard let token = TMDBCredential.load() else { return false }
        let client = TMDBClient(token: token)
        do {
            var info = try await client.details(candidate.kind, id: candidate.id)
            if let show = show(id) { info.seasons = try await client.seasons(show.seasons.map(\.number), of: info) }
            metadata[id] = info; unmatched.remove(id); saveMetadata()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    // MARK: Mi lista and watched state

    func toggleWatchlist(_ id: String) {
        if watchlist.contains(id) { watchlist.remove(id) } else { watchlist.insert(id) }
        try? Files.save(watchlist, name: watchlistName)
    }

    func markWatched(_ id: String, duration: Double? = nil) {
        let length = duration ?? progress[id]?.duration ?? 1
        progress[id] = WatchProgress(position: length, duration: length, updated: Date())
        saveProgress()
    }

    // MARK: Lookups

    func info(_ id: String) -> MediaInfo? { metadata[id] }

    func title(_ movie: Movie) -> String { metadata[movie.id]?.title.nonEmpty ?? movie.title }
    func title(_ show: Show) -> String { metadata[show.id]?.title.nonEmpty ?? show.title }
    func year(_ movie: Movie) -> Int? { metadata[movie.id]?.year ?? movie.year }
    func year(_ show: Show) -> Int? { metadata[show.id]?.year ?? show.year }

    func movie(_ id: String) -> Movie? { library.movies.first { $0.id == id } }
    func show(_ id: String) -> Show? { library.shows.first { $0.id == id } }

    /// The show an episode belongs to.
    func show(containing episodeID: String) -> Show? {
        library.shows.first { $0.seasons.contains { $0.episodes.contains { $0.id == episodeID } } }
    }

    /// The first unfinished episode, or the one after the last finished.
    func nextEpisode(_ show: Show) -> Episode? {
        let episodes = show.seasons.filter { $0.number > 0 }.flatMap(\.episodes)
        if let current = episodes.filter({ progress[$0.id]?.resumable == true }).max(by: { (progress[$0.id]?.updated ?? .distantPast) < (progress[$1.id]?.updated ?? .distantPast) }) { return current }
        if let last = episodes.lastIndex(where: { progress[$0.id]?.finished == true }), last + 1 < episodes.count { return episodes[last + 1] }
        return episodes.first
    }

    func request(id: String) -> PlaybackRequest? {
        if let movie = movie(id) { return request(movie: movie) }
        if let show = show(containing: id), let episode = show.seasons.flatMap(\.episodes).first(where: { $0.id == id }) { return request(episode: episode, show: show) }
        if let clip = library.videos.first(where: { $0.id == id }) { return request(clip: clip) }
        return nil
    }

    var featured: [String] {
        let movies = library.movies.map(\.id) + library.shows.map(\.id)
        let withArt = movies.filter { metadata[$0]?.backdropPath != nil }
        let recent = withArt.sorted { (library.addedAt[$0] ?? .distantPast) > (library.addedAt[$1] ?? .distantPast) }
        let top = withArt.sorted { (metadata[$0]?.rating ?? 0) > (metadata[$1]?.rating ?? 0) }
        var result: [String] = []
        for id in Array(recent.prefix(3)) + top where !result.contains(id) && result.count < 5 { result.append(id) }
        return result
    }

    var recommended: [String] {
        let candidates = library.movies.map(\.id) + library.shows.map(\.id)
        let watched = progress.keys.flatMap { id -> [String] in show(containing: id).map { [$0.id] } ?? [id] }
        let finished = Set(library.movies.map(\.id).filter { progress[$0]?.finished == true })
        return Array(Catalog.recommended(candidates: candidates, info: metadata, watched: watched, exclude: finished).prefix(12))
    }

    var recentlyAdded: [String] {
        (library.movies.map(\.id) + library.shows.map(\.id))
            .sorted { (library.addedAt[$0] ?? .distantPast) > (library.addedAt[$1] ?? .distantPast) }
            .prefix(12).map { $0 }
    }

    func related(_ id: String) -> [String] {
        let pool = metadata[id]?.kind == .tv ? library.shows.map(\.id) : library.movies.map(\.id)
        return Catalog.related(to: id, among: pool, info: metadata)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
