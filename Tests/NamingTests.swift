import XCTest
@testable import LFAZVideos

final class NamingTests: XCTestCase {
    func testMovieWithYearInParentheses() {
        XCTAssertEqual(MediaNaming.movie("Interstellar (2014).mkv"), .init(title: "Interstellar", year: 2014, tags: []))
        XCTAssertEqual(MediaNaming.movie("Dune: Parte Dos (2024) [2160p HDR].mkv").title, "Dune: Parte Dos")
        XCTAssertEqual(MediaNaming.movie("Dune: Parte Dos (2024) [2160p HDR].mkv").tags, ["4K", "HDR"])
    }
    func testDottedReleaseName() {
        let movie = MediaNaming.movie("Dune.Part.Two.2024.2160p.WEB-DL.HDR.Atmos.mkv")
        XCTAssertEqual(movie.title, "Dune Part Two")
        XCTAssertEqual(movie.year, 2024)
        XCTAssertEqual(movie.tags, ["4K", "HDR", "Dolby Atmos"])
    }
    func testNumbersInTitlesAreNotYears() {
        XCTAssertEqual(MediaNaming.movie("Blade Runner 2049 (2017).mkv"), .init(title: "Blade Runner 2049", year: 2017, tags: []))
        XCTAssertEqual(MediaNaming.movie("Blade Runner 2049.mkv").title, "Blade Runner 2049")
        XCTAssertNil(MediaNaming.movie("Blade Runner 2049.mkv").year)
        XCTAssertEqual(MediaNaming.movie("1917.mp4").title, "1917")
        XCTAssertNil(MediaNaming.movie("1917.mp4").year)
    }
    func testEpisodeCodes() {
        XCTAssertEqual(MediaNaming.episode("The Last of Us S01E04 - Por favor, sujeta mi mano.mkv"), .init(season: 1, number: 4, lastNumber: nil, title: "Por favor, sujeta mi mano"))
        XCTAssertEqual(MediaNaming.episode("Show.S02E05E06.720p.mkv"), .init(season: 2, number: 5, lastNumber: 6, title: nil))
        XCTAssertEqual(MediaNaming.episode("1x03 Piloto.mp4"), .init(season: 1, number: 3, lastNumber: nil, title: "Piloto"))
        XCTAssertEqual(MediaNaming.episode("Episodio 7.mkv")?.number, 7)
        XCTAssertNil(MediaNaming.episode("Detrás de cámaras.mkv"))
    }
    func testSeasonFolders() {
        XCTAssertEqual(MediaNaming.season("Temporada 2"), 2)
        XCTAssertEqual(MediaNaming.season("Season 01"), 1)
        XCTAssertEqual(MediaNaming.season("Especiales"), 0)
        XCTAssertNil(MediaNaming.season("Backstage"))
    }
    func testSectionFolderNames() {
        XCTAssertEqual(LibrarySection.matching(folder: "Películas"), .movies)
        XCTAssertEqual(LibrarySection.matching(folder: "Peliculas HD"), .movies)
        XCTAssertEqual(LibrarySection.matching(folder: "Movies"), .movies)
        XCTAssertEqual(LibrarySection.matching(folder: "Series de TV"), .series)
        XCTAssertEqual(LibrarySection.matching(folder: "TV Shows"), .series)
        XCTAssertEqual(LibrarySection.matching(folder: "Videos musicales"), .videos)
        XCTAssertEqual(LibrarySection.matching(folder: "Videoclips"), .videos)
        XCTAssertNil(LibrarySection.matching(folder: "@eaDir"))
        XCTAssertNil(LibrarySection.matching(folder: "Fotos"))
    }
    func testShowTitles() {
        XCTAssertEqual(MediaNaming.show("The Last of Us (2023)").title, "The Last of Us")
        XCTAssertEqual(MediaNaming.show("The Last of Us (2023)").year, 2023)
        XCTAssertEqual(MediaNaming.showTitle(fromEpisode: "Dark S01E01.mkv"), "Dark")
        XCTAssertNil(MediaNaming.showTitle(fromEpisode: "S01E01.mkv"))
    }
    func testMusicVideoNames() {
        XCTAssertEqual(MediaNaming.clip("The Weeknd - Blinding Lights (Official Video).mp4"), .init(title: "Blinding Lights", artist: "The Weeknd"))
        XCTAssertEqual(MediaNaming.clip("Mark Ronson - Uptown Funk ft. Bruno Mars.mp4"), .init(title: "Uptown Funk ft. Bruno Mars", artist: "Mark Ronson"))
        XCTAssertEqual(MediaNaming.clip("Faded.mp4").artist, "Artista desconocido")
    }
}

final class LibraryBuilderTests: XCTestCase {
    private let base = URL(string: "https://nas.example:5006/video/")!
    private func file(_ section: LibrarySection, _ path: String, date: TimeInterval = 0) -> ScannedFile {
        let parts = path.components(separatedBy: "/")
        let url = parts.reduce(base.appendingPathComponent(section.title)) { $0.appendingPathComponent($1) }
        return ScannedFile(section: section, folders: Array(parts.dropLast()), name: parts.last!, url: url, bytes: 100, modified: Date(timeIntervalSince1970: date))
    }

    func testMoviesUseFolderYearAndSkipSamples() {
        let library = LibraryBuilder.build([
            file(.movies, "Interstellar (2014)/Interstellar.2160p.mkv"),
            file(.movies, "Interstellar (2014)/interstellar-sample.mkv")
        ])
        XCTAssertEqual(library.movies.count, 1)
        XCTAssertEqual(library.movies.first?.title, "Interstellar")
        XCTAssertEqual(library.movies.first?.year, 2014)
        XCTAssertEqual(library.movies.first?.tags, ["4K"])
    }

    func testSeriesGroupSeasonsAndPreferNativeDuplicates() throws {
        let library = LibraryBuilder.build([
            file(.series, "The Last of Us (2023)/Temporada 1/The Last of Us S01E02.mkv", date: 10),
            file(.series, "The Last of Us (2023)/Temporada 1/The Last of Us S01E02.mp4", date: 10),
            file(.series, "The Last of Us (2023)/Temporada 1/The Last of Us S01E01.mkv", date: 5),
            file(.series, "The Last of Us (2023)/Temporada 2/Episodio 3.mkv", date: 30),
            file(.series, "Dark S01E01.mkv")
        ])
        XCTAssertEqual(library.shows.map(\.title), ["Dark", "The Last of Us"])
        let show = try XCTUnwrap(library.shows.last)
        XCTAssertEqual(show.year, 2023)
        XCTAssertEqual(show.seasons.map(\.number), [1, 2])
        XCTAssertEqual(show.seasons[0].episodes.map(\.number), [1, 2])
        XCTAssertEqual(show.seasons[0].episodes[1].file.format, "MP4")
        XCTAssertEqual(show.seasons[1].episodes.first?.number, 3)
        XCTAssertEqual(show.seasonCount, 2)
        XCTAssertEqual(library.addedAt[show.id], Date(timeIntervalSince1970: 30))
    }

    func testMusicVideosTakeGenreFromFolderAndMatchingThumbnail() {
        let library = LibraryBuilder.build([
            file(.videos, "Pop/Dua Lipa - Levitating.mp4"),
            file(.videos, "Pop/Dua Lipa - Levitating.jpg"),
            file(.videos, "Alan Walker - Faded.mkv")
        ])
        XCTAssertEqual(library.videos.map(\.artist), ["Alan Walker", "Dua Lipa"])
        XCTAssertEqual(library.videos.last?.genre, "Pop")
        XCTAssertEqual(library.videos.last?.thumbnail?.lastPathComponent, "Dua Lipa - Levitating.jpg")
        XCTAssertEqual(library.videos.first?.genre, "Sin género")
        XCTAssertNil(library.videos.first?.thumbnail)
    }
}

final class ConnectionTests: XCTestCase {
    func testHTTPSAndFolderBoundary() throws {
        let root = try URLPolicy.root("https://nas.example:5006/video")
        XCTAssertEqual(root.absoluteString, "https://nas.example:5006/video/")
        XCTAssertThrowsError(try URLPolicy.root("http://nas.example/video/"))
        XCTAssertThrowsError(try URLPolicy.root("https://user:pass@nas.example/video/"))
        XCTAssertFalse(URLPolicy.allowed(URL(string: "https://nas.example:5006/video2/a.mkv")!, root: root))
        XCTAssertFalse(URLPolicy.allowed(URL(string: "https://evil.example:5006/video/a.mkv")!, root: root))
        XCTAssertFalse(URLPolicy.allowed(URL(string: "https://nas.example:5006/video/%2e%2e/a.mkv")!, root: root))
        XCTAssertTrue(URLPolicy.allowed(URL(string: "https://nas.example:5006/video/Pel%C3%ADculas/a.mkv")!, root: root))
    }
    func testRoutesFollowConnectionMode() throws {
        var account = NASAccount(root: try URLPolicy.root("https://nas.example/video/"), username: "u", password: "p", routeIP: "192.168.0.10", tailscaleHost: "100.64.0.20", connectionMode: .automatic)
        XCTAssertEqual(account.routes, ["192.168.0.10", "100.64.0.20"])
        account.connectionMode = .tailscale
        XCTAssertEqual(account.routes, ["100.64.0.20"])
        XCTAssertFalse(NASAccount.validRoute("192.168.0.10:5006"))
    }
    func testDAVListsChildrenWithDatesAndSkipsOtherHosts() throws {
        let root = try URLPolicy.root("https://nas.example/video/")
        func response(_ path: String, folder: Bool = false) -> String {
            "<d:response><d:href>\(path)</d:href><d:propstat><d:prop>" + (folder ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:getcontentlength>123</d:getcontentlength>") +
            "<d:getlastmodified>Wed, 14 Oct 2026 16:39:55 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }
        let xml = "<d:multistatus xmlns:d='DAV:'>" + response("/video/") + response("/video/Pel%C3%ADculas/", folder: true) + response("/video/a.mkv") + response("https://evil.example/video/b.mkv") + "</d:multistatus>"
        let entries = try DAVParser.parse(Data(xml.utf8), folder: root)
        XCTAssertEqual(entries.map(\.name), ["a.mkv", "Películas"])
        XCTAssertEqual(entries.first?.video, true)
        XCTAssertEqual(entries.last?.directory, true)
        XCTAssertEqual(entries.first?.modified, Date(timeIntervalSince1970: 1_791_995_995))
    }
}
