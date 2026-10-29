import Foundation

/// A file found under one of the section folders. `folders` are the folder names
/// between the section folder and the file (`["The Last of Us", "Temporada 1"]`).
struct ScannedFile: Equatable {
    var section: LibrarySection
    var folders: [String]
    var name: String
    var url: URL
    var bytes: Int64?
    var modified: Date?
    var isImage: Bool { ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) }
}

enum LibraryBuilder {
    static func build(_ files: [ScannedFile], missing: [LibrarySection] = []) -> Library {
        let videos = files.filter { !$0.isImage && !ignored($0) }
        var library = Library()
        library.movies = movies(videos.filter { $0.section == .movies })
        library.shows = shows(videos.filter { $0.section == .series })
        library.videos = clips(videos.filter { $0.section == .videos }, images: files.filter { $0.section == .videos && $0.isImage })
        library.missingSections = missing
        for file in videos { if let date = file.modified { library.addedAt[file.url.absoluteString] = date } }
        // A show counts as added when its newest episode arrived.
        for show in library.shows {
            let dates = show.seasons.flatMap(\.episodes).compactMap { library.addedAt[$0.id] }
            if let newest = dates.max() { library.addedAt[show.id] = newest }
        }
        return library
    }

    private static func ignored(_ file: ScannedFile) -> Bool {
        let key = file.name.searchKey
        return key.hasPrefix(".") || key.hasPrefix("._") || key.contains("sample") || file.folders.contains { ["@eadir", "#recycle", "featurettes"].contains($0.searchKey) }
    }

    private static func movies(_ files: [ScannedFile]) -> [Movie] {
        files.map { file in
            var parsed = MediaNaming.movie(file.name)
            if let folder = file.folders.last {
                let fromFolder = MediaNaming.movie(folder + ".folder")
                if parsed.year == nil, fromFolder.year != nil { parsed.title = fromFolder.title; parsed.year = fromFolder.year }
                parsed.tags += fromFolder.tags.filter { !parsed.tags.contains($0) }
            }
            return Movie(id: file.url.absoluteString, title: parsed.title, year: parsed.year, file: VideoFile(url: file.url, bytes: file.bytes), tags: parsed.tags)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func shows(_ files: [ScannedFile]) -> [Show] {
        var groups: [String: (title: String, year: Int?, files: [ScannedFile])] = [:]
        for file in files {
            let title: String, year: Int?
            if let folder = file.folders.first { (title, year) = MediaNaming.show(folder) }
            else { title = MediaNaming.showTitle(fromEpisode: file.name) ?? "Sin clasificar"; year = nil }
            groups[title.searchKey, default: (title, year, [])].files.append(file)
        }
        return groups.map { key, group in
            var seasons: [Int: [Episode]] = [:]
            for file in group.files {
                let parsed = MediaNaming.episode(file.name)
                let folderSeason = file.folders.dropFirst().compactMap(MediaNaming.season).last
                let season = parsed?.season ?? folderSeason ?? 1
                let episode = Episode(id: file.url.absoluteString, season: season, number: parsed?.number ?? 0, lastNumber: parsed?.lastNumber,
                                      title: parsed == nil ? MediaNaming.cleanTitle((file.name as NSString).deletingPathExtension) : parsed?.title,
                                      file: VideoFile(url: file.url, bytes: file.bytes))
                if let index = seasons[season]?.firstIndex(where: { $0.number == episode.number && episode.number > 0 }) {
                    // Same episode in two formats: keep the one AVPlayer plays natively.
                    if episode.file.native && !(seasons[season]![index].file.native) { seasons[season]![index] = episode }
                } else { seasons[season, default: []].append(episode) }
            }
            let list = seasons.map { number, episodes in
                Season(number: number, episodes: episodes.sorted { ($0.number, $0.title ?? "") < ($1.number, $1.title ?? "") })
            }.sorted { ($0.number == 0 ? Int.max : $0.number) < ($1.number == 0 ? Int.max : $1.number) }
            return Show(id: "show:" + key, title: group.title, year: group.year, seasons: list)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func clips(_ files: [ScannedFile], images: [ScannedFile]) -> [MusicVideo] {
        func key(_ file: ScannedFile) -> String { (file.folders + [(file.name as NSString).deletingPathExtension]).joined(separator: "/").searchKey }
        let thumbnails = Dictionary(images.map { (key($0), $0.url) }, uniquingKeysWith: { first, _ in first })
        return files.map { file in
            let parsed = MediaNaming.clip(file.name)
            return MusicVideo(id: file.url.absoluteString, title: parsed.title, artist: parsed.artist,
                              genre: file.folders.first.map(MediaNaming.cleanTitle) ?? "Sin género",
                              file: VideoFile(url: file.url, bytes: file.bytes), thumbnail: thumbnails[key(file)])
        }.sorted { ($0.artist.searchKey, $0.title.searchKey) < ($1.artist.searchKey, $1.title.searchKey) }
    }
}
