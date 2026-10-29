import Foundation

/// What TMDB knows about one movie or show in the library.
struct MediaInfo: Codable, Equatable {
    enum Kind: String, Codable { case movie, tv }
    struct Person: Codable, Equatable, Hashable { var name: String; var role: String; var profilePath: String? }
    struct EpisodeInfo: Codable, Equatable { var number: Int; var name: String; var overview: String; var stillPath: String?; var runtime: Int? }
    struct SeasonInfo: Codable, Equatable { var number: Int; var name: String; var posterPath: String?; var episodes: [EpisodeInfo] }

    var tmdbID: Int
    var kind: Kind
    var title: String
    var originalTitle: String?
    var tagline: String?
    var overview: String
    var year: Int?
    var runtime: Int?
    var genres: [String]
    var rating: Double?
    var posterPath: String?
    var backdropPath: String?
    var backdrops: [String] = []
    var cast: [Person] = []
    var directors: [String] = []
    var languages: [String] = []
    var collectionID: Int?
    var collectionName: String?
    var seasons: [SeasonInfo] = []

    func episode(season: Int, number: Int) -> EpisodeInfo? {
        seasons.first { $0.number == season }?.episodes.first { $0.number == number }
    }
}

/// Lookups the screens need, kept apart from SwiftUI so they can be tested.
enum Catalog {
    /// Genres in the order they're most common in `items`.
    static func genres(_ infos: [MediaInfo?]) -> [String] {
        var counts: [String: Int] = [:]
        for info in infos { for genre in info?.genres ?? [] { counts[genre, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Scores unwatched titles by how often their genres appear in what was watched, then by rating.
    static func recommended(candidates: [String], info: [String: MediaInfo], watched: [String], exclude: Set<String>) -> [String] {
        var weights: [String: Double] = [:]
        for id in watched { for genre in info[id]?.genres ?? [] { weights[genre, default: 0] += 1 } }
        func score(_ id: String) -> Double {
            let item = info[id]
            let affinity = (item?.genres ?? []).reduce(0) { $0 + (weights[$1] ?? 0) }
            return affinity * 10 + (item?.rating ?? 0)
        }
        return candidates.filter { !exclude.contains($0) }.sorted { score($0) > score($1) }
    }

    /// Titles of the same TMDB collection, otherwise the ones sharing the most genres.
    static func related(to id: String, among candidates: [String], info: [String: MediaInfo]) -> [String] {
        guard let base = info[id] else { return [] }
        let others = candidates.filter { $0 != id }
        if let collection = base.collectionID {
            let saga = others.filter { info[$0]?.collectionID == collection }
            if !saga.isEmpty { return saga.sorted { (info[$0]?.year ?? 0) < (info[$1]?.year ?? 0) } }
        }
        let genres = Set(base.genres)
        return others
            .map { ($0, Set(info[$0]?.genres ?? []).intersection(genres).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : (info[$0.0]?.rating ?? 0) > (info[$1.0]?.rating ?? 0) }
            .map(\.0)
    }

    static func runtimeText(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "es").localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: "es")) ?? code
    }
}
