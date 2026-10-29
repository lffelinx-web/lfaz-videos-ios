import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var account: NASAccount?
    @Published private(set) var library = Library()
    @Published private(set) var busy = false
    @Published private(set) var status = "Sin conectar"
    @Published private(set) var nasConnected: Bool?
    @Published var error: String?
    @Published var libraryFeedback: String?
    @Published var progress: [String: WatchProgress] = [:]
    /// The video VLC is showing; MP4 files open in the native player instead.
    @Published var vlcSession: VLCSession?
    @Published private(set) var opening: String?
    @Published var metadata: [String: MediaInfo] = [:]
    /// Titles TMDB had no match for, so they are not searched again on every launch.
    @Published var unmatched: Set<String> = []
    @Published var watchlist: Set<String> = []
    @Published var hasTMDB = TMDBCredential.load() != nil
    @Published var enrichStatus: String?
    var enrichTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    private var libraryName: String { "library-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    private var progressName: String { "progress-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    var metadataName: String { "metadata-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }
    var watchlistName: String { "watchlist-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }

    init() {
        account = AccountKeychain.load()
        if account != nil {
            library = Files.load(libraryName, as: Library.self) ?? Library()
            progress = Files.load(progressName, as: [String: WatchProgress].self) ?? [:]
            loadExtras()
            status = library.isEmpty ? "Cuenta guardada" : summary(library)
        }
    }

    var connectionLabel: String {
        switch nasConnected { case .some(true): return "Conectado"; case .some(false): return "Sin conexión"; case .none: return account == nil ? "Sin configurar" : "Comprobando…" }
    }

    func connect(root: String, user: String, password: String, route: String, tailscale: String, mode: NASConnectionMode) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do {
            let candidate = NASAccount(root: try URLPolicy.root(root), username: user.trimmingCharacters(in: .whitespaces), password: password,
                                       routeIP: route.trimmingCharacters(in: .whitespaces), tailscaleHost: tailscale.trimmingCharacters(in: .whitespacesAndNewlines), connectionMode: mode)
            guard !candidate.username.isEmpty, !password.isEmpty, NASAccount.validRoute(candidate.routeIP), NASAccount.validRoute(candidate.tailscaleHost ?? ""), !candidate.routes.isEmpty else {
                throw VideoError.message("Revisa usuario, contraseña e IP de conexión.")
            }
            _ = try await NASTransport(candidate).list(candidate.root)
            try AccountKeychain.save(candidate)
            if account?.scope != candidate.scope {
                scanTask?.cancel()
                account = candidate
                library = Files.load(libraryName, as: Library.self) ?? Library()
                progress = Files.load(progressName, as: [String: WatchProgress].self) ?? [:]
                loadExtras()
            } else { account = candidate }
            nasConnected = true; status = "Conectado"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func disconnect() {
        do { try AccountKeychain.clear() } catch { self.error = error.localizedDescription; return }
        scanTask?.cancel(); enrichTask?.cancel(); account = nil; library = Library(); progress = [:]; metadata = [:]; unmatched = []; watchlist = []; nasConnected = nil; status = "Sin conectar"
    }

    /// Checks the NAS when the app opens so the status reflects the current network.
    func checkConnection() async {
        guard let account, !busy else { return }
        do { _ = try await NASTransport(account).list(account.root); nasConnected = true }
        catch { nasConnected = false }
    }

    func synchronize() {
        guard let account, !busy else { return }
        busy = true; libraryFeedback = nil; status = "Buscando videos…"
        scanTask = Task {
            defer { busy = false }
            do {
                let scanned = try await LibraryScanner(account: account).scan { [weak self] text in
                    Task { @MainActor in self?.status = "Leyendo \(text)" }
                }
                guard self.account?.scope == account.scope else { return }
                library = scanned; nasConnected = true
                try? Files.save(library, name: libraryName)
                status = summary(library)
                let missing = library.missingSections.map(\.title)
                libraryFeedback = missing.isEmpty ? "Biblioteca actualizada" : "Biblioteca actualizada. No se encontró: " + missing.joined(separator: ", ")
                enrichMetadata()
            } catch is CancellationError {
                status = summary(library)
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription; status = summary(library)
            }
        }
    }

    // MARK: Playback

    func play(_ request: PlaybackRequest) {
        guard let account, opening == nil else { return }
        var request = request
        if request.start == 0, let saved = progress[request.id], saved.resumable { request.start = saved.position }
        opening = request.id
        Task {
            defer { opening = nil }
            do {
                let url = try await StreamServer.shared.url(for: request.file, account: account)
                let id = request.id
                if request.file.native {
                    NativePlayerController.present(url: url, title: request.title, start: request.start,
                                                   onProgress: { [weak self] position, duration in self?.record(id, position: position, duration: duration) },
                                                   onClose: { [weak self] in self?.saveProgress() })
                } else {
                    vlcSession = VLCSession(request: request, url: url)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func record(_ id: String, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        progress[id] = WatchProgress(position: position, duration: duration, updated: Date())
    }

    func saveProgress() { try? Files.save(progress, name: progressName) }

    func clearProgress(_ id: String) { progress[id] = nil; saveProgress() }

    func request(movie: Movie) -> PlaybackRequest {
        PlaybackRequest(id: movie.id, title: movie.title, subtitle: movie.year.map(String.init) ?? "", file: movie.file)
    }

    func request(episode: Episode, show: Show) -> PlaybackRequest {
        PlaybackRequest(id: episode.id, title: show.title, subtitle: episode.code + (episode.title.map { " · " + $0 } ?? ""), file: episode.file)
    }

    func request(clip: MusicVideo) -> PlaybackRequest {
        PlaybackRequest(id: clip.id, title: clip.title, subtitle: clip.artist, file: clip.file)
    }

    /// Movies, episodes and clips started but not finished, most recent first.
    var continueWatching: [(request: PlaybackRequest, progress: WatchProgress)] {
        var all: [String: PlaybackRequest] = [:]
        for movie in library.movies { all[movie.id] = request(movie: movie) }
        for show in library.shows { for season in show.seasons { for episode in season.episodes { all[episode.id] = request(episode: episode, show: show) } } }
        for clip in library.videos { all[clip.id] = request(clip: clip) }
        return progress.filter { $0.value.resumable }
            .compactMap { id, value -> (request: PlaybackRequest, progress: WatchProgress)? in all[id].map { (request: $0, progress: value) } }
            .sorted { $0.progress.updated > $1.progress.updated }
    }

    private func summary(_ library: Library) -> String {
        [countText(library.movies.count, "película", "películas"), countText(library.shows.count, "serie", "series"), countText(library.videos.count, "video", "videos")].joined(separator: " · ")
    }
}

struct VLCSession: Identifiable {
    let request: PlaybackRequest
    let url: URL
    var id: String { request.id }
}
