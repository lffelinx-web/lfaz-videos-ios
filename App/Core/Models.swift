import Foundation

struct NASAccount: Codable, Equatable {
    var root: URL
    var username: String
    var password: String
    var routeIP: String
    var tailscaleHost: String?
    var connectionMode: NASConnectionMode?
    var scope: String { root.absoluteString + "|" + username }
}

enum VideoFormat {
    static let supported: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts"]
    /// Formats AVPlayer decodes natively; the rest need the VLC-based player.
    static let native: Set<String> = ["mp4", "m4v", "mov"]
}

enum LibrarySection: String, Codable, CaseIterable, Identifiable {
    case movies, series, videos
    var id: String { rawValue }
    var title: String { switch self { case .movies: return "Películas"; case .series: return "Series"; case .videos: return "Videos" } }
    var symbol: String { switch self { case .movies: return "film"; case .series: return "tv"; case .videos: return "play.rectangle" } }
    /// Word prefixes that identify a section folder: `Películas HD`, `Series de TV`, `Videos musicales`.
    var folderWords: [String] {
        switch self {
        case .movies: return ["pelicul", "peli", "movie", "film", "cine"]
        case .series: return ["serie", "tv", "show"]
        case .videos: return ["video", "clip", "musica", "music"]
        }
    }
    static func matching(folder name: String) -> LibrarySection? {
        let key = name.searchKey
        guard let first = key.first, !["@", "#", "."].contains(first) else { return nil }
        let words = key.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return allCases.first { section in words.contains { word in section.folderWords.contains { word.hasPrefix($0) } } }
    }
}

struct VideoFile: Codable, Equatable, Hashable {
    var url: URL
    var bytes: Int64?
    var format: String { url.pathExtension.uppercased() }
    var native: Bool { VideoFormat.native.contains(url.pathExtension.lowercased()) }
}

struct Movie: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var year: Int?
    var file: VideoFile
    var tags: [String] = []
}

struct Episode: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var season: Int
    var number: Int
    var lastNumber: Int?
    var title: String?
    var file: VideoFile
    var code: String { "T\(season) · E\(number)" + (lastNumber.map { "-\($0)" } ?? "") }
}

struct Season: Codable, Identifiable, Equatable, Hashable {
    var number: Int
    var episodes: [Episode]
    var id: Int { number }
    var title: String { number == 0 ? "Especiales" : "Temporada \(number)" }
}

struct Show: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var year: Int?
    var seasons: [Season]
    var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
    var seasonCount: Int { seasons.filter { $0.number > 0 }.count }
}

struct MusicVideo: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var artist: String
    var genre: String
    var file: VideoFile
    var thumbnail: URL?
}

struct Library: Codable, Equatable {
    var movies: [Movie] = []
    var shows: [Show] = []
    var videos: [MusicVideo] = []
    var addedAt: [String: Date] = [:]
    var missingSections: [LibrarySection] = []
    var isEmpty: Bool { movies.isEmpty && shows.isEmpty && videos.isEmpty }
}

enum VideoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func countText(_ count: Int, _ singular: String, _ plural: String) -> String { "\(count) \(count == 1 ? singular : plural)" }

extension String {
    var searchKey: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    func matches(_ query: String) -> Bool {
        let haystack = searchKey
        return query.searchKey.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}
