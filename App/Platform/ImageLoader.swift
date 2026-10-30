import UIKit
import ImageIO

/// Where an artwork comes from: TMDB's image CDN or a `.jpg` next to a video on the NAS.
enum ImageSource: Hashable {
    case tmdb(String, size: String)
    case nas(URL)
    /// A still taken from the video itself.
    case frame(VideoFile)

    var key: String {
        switch self {
        case .tmdb(let path, let size): return "tmdb\(size)\(path)"
        case .nas(let url): return "nas" + url.absoluteString
        case .frame(let file): return "frame" + file.url.absoluteString
        }
    }
}

/// Downloads artwork once, keeps it on disk in Caches and decoded in memory.
actor ImageLoader {
    static let shared = ImageLoader()
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 96 * 1_048_576; return cache
    }()
    private var running: [String: Task<UIImage?, Never>] = [:]
    private let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated func cached(_ source: ImageSource, maxPixels: CGFloat) -> UIImage? { memory.object(forKey: (source.key + "#\(Int(maxPixels))") as NSString) }

    func image(_ source: ImageSource, account: NASAccount?, maxPixels: CGFloat) async -> UIImage? {
        let key = source.key + "#\(Int(maxPixels))"
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = running[key] { return await task.value }
        let file = folder.appendingPathComponent(Files.key(source.key) + ".img")
        let task = Task<UIImage?, Never> {
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let data = await Self.download(source, account: account), data.count < 15_000_000 else { return nil }
                try? data.write(to: file, options: .atomic)
            }
            return Self.decode(file, maxPixels: maxPixels)
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }

    private static func download(_ source: ImageSource, account: NASAccount?) async -> Data? {
        switch source {
        case .tmdb(let path, let size):
            guard let url = TMDBImage.url(path, size: size) else { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        case .nas(let url):
            guard let account else { return nil }
            return try? await NASTransport(account).request(url, limit: 15_000_000).data
        case .frame(let file):
            guard let account else { return nil }
            return await FrameGrabber.jpeg(file, account: account)
        }
    }

    private static func decode(_ file: URL, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
