import AVFoundation
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// Takes a still from a quarter of the way into a video, through the local stream server,
/// for music videos that have no `.jpg` next to them on the NAS.
enum FrameGrabber {
    /// Each still opens the video over the network; take at most two at a time.
    private static let gate = Gate(limit: 2)

    static func jpeg(_ file: VideoFile, account: NASAccount) async -> Data? {
        await gate.wait()
        defer { Task { await gate.signal() } }
        guard let url = try? await StreamServer.shared.url(for: file, account: account) else { return nil }
        let image: CGImage?
        if file.native { image = await native(url) } else { image = await vlc(url) }
        return image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.8) }
    }

    private static func native(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let time = CMTime(seconds: min(max(duration.seconds * 0.25, 1), max(duration.seconds - 1, 0)), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    #if canImport(MobileVLCKit)
    private static func vlc(_ url: URL) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { VLCFrame(url: url) { continuation.resume(returning: $0) }.start() }
        }
    }
    #else
    private static func vlc(_ url: URL) async -> CGImage? { nil }
    #endif
}

#if canImport(MobileVLCKit)
/// Keeps the VLC thumbnailer alive until it answers, and answers exactly once.
private final class VLCFrame: NSObject, VLCMediaThumbnailerDelegate {
    private static var running: Set<VLCFrame> = []
    private var thumbnailer: VLCMediaThumbnailer?
    private var completion: ((CGImage?) -> Void)?
    private let url: URL

    init(url: URL, completion: @escaping (CGImage?) -> Void) {
        self.url = url; self.completion = completion
    }

    func start() {
        Self.running.insert(self)
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=2000")
        let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
        thumbnailer.snapshotPosition = 0.25
        thumbnailer.thumbnailWidth = 960
        thumbnailer.thumbnailHeight = 540
        self.thumbnailer = thumbnailer
        thumbnailer.fetchThumbnail()
        // VLC reports a timeout on its own, but never leave a caller waiting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(nil) }
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) { finish(thumbnail) }
    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) { finish(nil) }

    private func finish(_ image: CGImage?) {
        DispatchQueue.main.async {
            guard let completion = self.completion else { return }
            self.completion = nil; self.thumbnailer = nil
            completion(image)
            Self.running.remove(self)
        }
    }
}
#endif

private actor Gate {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { available = limit }
    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func signal() {
        if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() }
    }
}
