import XCTest
@testable import LFAZVideos

final class CatalogTests: XCTestCase {
    private func info(_ id: Int, _ genres: [String], rating: Double = 5, collection: Int? = nil, year: Int? = nil) -> MediaInfo {
        MediaInfo(tmdbID: id, kind: .movie, title: "T\(id)", overview: "", year: year, genres: genres, rating: rating, collectionID: collection)
    }

    func testGenresOrderedByFrequency() {
        XCTAssertEqual(Catalog.genres([info(1, ["Drama", "Acción"]), info(2, ["Drama"]), nil]), ["Drama", "Acción"])
    }

    func testRecommendationsFollowWatchedGenres() {
        let all = ["a": info(1, ["Drama"], rating: 6), "b": info(2, ["Ciencia ficción"], rating: 9), "c": info(3, ["Drama"], rating: 7)]
        XCTAssertEqual(Catalog.recommended(candidates: ["a", "b", "c"], info: all, watched: ["a"], exclude: ["a"]), ["c", "b"])
    }

    func testRelatedPrefersCollectionInYearOrder() {
        let all = ["a": info(1, ["Acción"], collection: 9, year: 2001), "b": info(2, ["Acción"], collection: 9, year: 1999), "c": info(3, ["Acción"], rating: 9)]
        XCTAssertEqual(Catalog.related(to: "a", among: ["a", "b", "c"], info: all), ["b"])
        XCTAssertEqual(Catalog.related(to: "c", among: ["a", "b", "c"], info: all).count, 2)
    }

    func testRuntimeText() {
        XCTAssertEqual(Catalog.runtimeText(138), "2 h 18 min")
        XCTAssertEqual(Catalog.runtimeText(45), "45 min")
        XCTAssertNil(Catalog.runtimeText(0))
    }
}
