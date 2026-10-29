import Foundation
import Security

/// The TMDB credential the user pastes in Ajustes: a v4 read token, or a v3 API key.
enum TMDBCredential {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LFaz.Videos.TMDB", kSecAttrAccount as String: "primary"] }
    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw VideoError.message("No se pudo guardar la clave de TMDB en el llavero.") }
    }
    static func load() -> String? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

enum TMDBImage {
    static func url(_ path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

struct TMDBClient {
    let token: String
    var language = "es-MX"

    private var isAPIKey: Bool { token.count == 32 && token.allSatisfy(\.isHexDigit) }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var query = items + [URLQueryItem(name: "language", value: language)]
        if isAPIKey { query.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        if !isAPIKey { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw VideoError.message("La clave de TMDB no es válida. Revísala en Ajustes.") }
        if status == 429 { try await Task.sleep(for: .seconds(2)); return try await get(path, items, as: type) }
        guard (200...299).contains(status) else { throw VideoError.message("TMDB respondió con el código \(status).") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func verify() async throws { _ = try await get("/configuration", as: Empty.self) }

    func movie(title: String, year: Int?) async throws -> MediaInfo? {
        var results = try await get("/search/movie", [URLQueryItem(name: "query", value: title), URLQueryItem(name: "include_adult", value: "false")] + (year.map { [URLQueryItem(name: "year", value: String($0))] } ?? []), as: Page.self).results
        if results.isEmpty, year != nil { results = try await get("/search/movie", [URLQueryItem(name: "query", value: title)], as: Page.self).results }
        guard let id = results.first?.id else { return nil }
        let detail = try await get("/movie/\(id)", [URLQueryItem(name: "append_to_response", value: "credits,images"), URLQueryItem(name: "include_image_language", value: "null")], as: Detail.self)
        var info = detail.info(kind: .movie)
        if info.overview.isEmpty { info.overview = (try? await englishOverview("/movie/\(id)")) ?? "" }
        return info
    }

    func show(title: String, year: Int?) async throws -> MediaInfo? {
        var results = try await get("/search/tv", [URLQueryItem(name: "query", value: title)] + (year.map { [URLQueryItem(name: "first_air_date_year", value: String($0))] } ?? []), as: Page.self).results
        if results.isEmpty, year != nil { results = try await get("/search/tv", [URLQueryItem(name: "query", value: title)], as: Page.self).results }
        guard let id = results.first?.id else { return nil }
        let detail = try await get("/tv/\(id)", [URLQueryItem(name: "append_to_response", value: "credits,images"), URLQueryItem(name: "include_image_language", value: "null")], as: Detail.self)
        var info = detail.info(kind: .tv)
        if info.overview.isEmpty { info.overview = (try? await englishOverview("/tv/\(id)")) ?? "" }
        return info
    }

    /// Fills in the episodes of the seasons present on the NAS.
    func seasons(_ numbers: [Int], of info: MediaInfo) async throws -> [MediaInfo.SeasonInfo] {
        var result: [MediaInfo.SeasonInfo] = []
        for number in numbers {
            guard let season = try? await get("/tv/\(info.tmdbID)/season/\(number)", as: SeasonDetail.self) else { continue }
            result.append(MediaInfo.SeasonInfo(number: number, name: season.name ?? "Temporada \(number)", posterPath: season.poster_path,
                                               episodes: (season.episodes ?? []).map { .init(number: $0.episode_number, name: $0.name ?? "", overview: $0.overview ?? "", stillPath: $0.still_path, runtime: $0.runtime) }))
        }
        return result
    }

    private func englishOverview(_ path: String) async throws -> String {
        var english = self; english.language = "en-US"
        return try await english.get(path, as: Detail.self).overview ?? ""
    }

    // MARK: Responses

    private struct Empty: Decodable {}
    private struct Page: Decodable { struct Item: Decodable { let id: Int }; let results: [Item] }
    private struct Named: Decodable { let name: String }
    private struct Language: Decodable { let iso_639_1: String }
    private struct Collection: Decodable { let id: Int; let name: String }
    private struct Credits: Decodable {
        struct Cast: Decodable { let name: String; let character: String?; let profile_path: String? }
        struct Crew: Decodable { let name: String; let job: String? }
        let cast: [Cast]?; let crew: [Crew]?
    }
    private struct Images: Decodable { struct Image: Decodable { let file_path: String }; let backdrops: [Image]? }
    private struct SeasonDetail: Decodable {
        struct Episode: Decodable { let episode_number: Int; let name: String?; let overview: String?; let still_path: String?; let runtime: Int? }
        let name: String?; let poster_path: String?; let episodes: [Episode]?
    }
    private struct Detail: Decodable {
        let id: Int
        let title: String?, name: String?, original_title: String?, original_name: String?
        let tagline: String?, overview: String?
        let release_date: String?, first_air_date: String?
        let runtime: Int?, episode_run_time: [Int]?
        let genres: [Named]?
        let vote_average: Double?
        let poster_path: String?, backdrop_path: String?
        let belongs_to_collection: Collection?
        let spoken_languages: [Language]?, original_language: String?
        let created_by: [Named]?
        let credits: Credits?
        let images: Images?

        func info(kind: MediaInfo.Kind) -> MediaInfo {
            let date = release_date ?? first_air_date ?? ""
            let directors = kind == .movie ? (credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name) : (created_by ?? []).map(\.name)
            var languages = (spoken_languages ?? []).map(\.iso_639_1)
            if let original = original_language, !languages.contains(original) { languages.insert(original, at: 0) }
            return MediaInfo(
                tmdbID: id, kind: kind, title: title ?? name ?? "", originalTitle: original_title ?? original_name,
                tagline: tagline.flatMap { $0.isEmpty ? nil : $0 }, overview: overview ?? "",
                year: Int(date.prefix(4)), runtime: runtime ?? episode_run_time?.first,
                genres: (genres ?? []).map(\.name), rating: vote_average,
                posterPath: poster_path, backdropPath: backdrop_path,
                backdrops: Array((images?.backdrops ?? []).map(\.file_path).prefix(12)),
                cast: Array((credits?.cast ?? []).prefix(20).map { .init(name: $0.name, role: $0.character ?? "", profilePath: $0.profile_path) }),
                directors: Array(directors.prefix(3)), languages: Array(languages.prefix(4)),
                collectionID: belongs_to_collection?.id, collectionName: belongs_to_collection?.name)
        }
    }
}
