import XCTest
@testable import LFAZVideos

final class PlaybackTests: XCTestCase {
    func testByteRanges() {
        XCTAssertEqual(ByteRange.parse(nil, total: 1000), ByteRange(start: 0, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=0-1", total: 1000), ByteRange(start: 0, end: 1))
        XCTAssertEqual(ByteRange.parse("bytes=500-", total: 1000), ByteRange(start: 500, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=900-5000", total: 1000), ByteRange(start: 900, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=-100", total: 1000), ByteRange(start: 900, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=0-9, 20-29", total: 1000)?.count, 10)
        XCTAssertNil(ByteRange.parse("bytes=1000-", total: 1000))
        XCTAssertNil(ByteRange.parse("bytes=50-10", total: 1000))
        XCTAssertNil(ByteRange.parse("bytes=0-", total: 0))
    }
    func testWatchProgress() {
        let start = WatchProgress(position: 10, duration: 6000, updated: Date())
        XCTAssertFalse(start.resumable)
        let middle = WatchProgress(position: 3000, duration: 6000, updated: Date())
        XCTAssertTrue(middle.resumable); XCTAssertEqual(middle.fraction, 0.5)
        let credits = WatchProgress(position: 5800, duration: 6000, updated: Date())
        XCTAssertTrue(credits.finished); XCTAssertFalse(credits.resumable)
        XCTAssertEqual(remainingText(4320), "1 h 12 min restantes")
        XCTAssertEqual(remainingText(20), "1 min restantes")
        XCTAssertEqual(clockText(3725), "1:02:05")
        XCTAssertEqual(MediaType.mime("MKV"), "video/x-matroska")
    }
}
