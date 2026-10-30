import Foundation
import UIKit

/// Offline copies and the temporary cache that lets videos rewind without the NAS.
extension AppStore {
    /// Music videos and other small files are cached whole while they play.
    static let wholeCacheLimit: Int64 = 600 * 1_048_576

    func file(for id: String) -> VideoFile? { request(id: id)?.file }

    func refreshDownloads() {
        var ids = Set<String>()
        for movie in library.movies where BlockCache.downloaded(movie.file) != nil { ids.insert(movie.id) }
        for show in library.shows { for episode in show.seasons.flatMap(\.episodes) where BlockCache.downloaded(episode.file) != nil { ids.insert(episode.id) } }
        for clip in library.videos where BlockCache.downloaded(clip.file) != nil { ids.insert(clip.id) }
        downloadedIDs = ids
    }

    /// Fills the cache with the rest of a short video in the background, so rewinding never waits.
    func cacheWhole(_ file: VideoFile) {
        guard let account, BlockCache.downloaded(file) == nil else { return }
        wholeCacheTask?.cancel()
        wholeCacheTask = Task(priority: .utility) {
            guard let total = try? await BlockCache.shared.length(file, account: account), total <= Self.wholeCacheLimit else { return }
            let blocks = (total + Int64(BlockCache.blockSize) - 1) / Int64(BlockCache.blockSize)
            for index in 0..<blocks {
                if Task.isCancelled { return }
                _ = try? await BlockCache.shared.block(index, of: file, account: account)
            }
        }
    }

    // MARK: Downloads

    func download(_ id: String) {
        guard file(for: id) != nil, !downloadedIDs.contains(id), downloadProgress[id] == nil else { return }
        downloadProgress[id] = 0
        downloadQueue.append(id)
        runDownloads()
    }

    func cancelDownload(_ id: String) {
        downloadQueue.removeAll { $0 == id }
        if activeDownload == id { downloadTask?.cancel() }
        downloadProgress[id] = nil
    }

    func removeDownload(_ id: String) {
        if let file = file(for: id), let local = BlockCache.downloaded(file) { try? FileManager.default.removeItem(at: local) }
        downloadedIDs.remove(id)
    }

    func removeAllDownloads() {
        downloadQueue.removeAll(); downloadTask?.cancel()
        try? FileManager.default.removeItem(at: BlockCache.downloadsFolder)
        downloadedIDs = []; downloadProgress = [:]
    }

    private func runDownloads() {
        guard downloadTask == nil, let account, !downloadQueue.isEmpty else { return }
        let id = downloadQueue.removeFirst()
        guard let file = file(for: id) else { downloadProgress[id] = nil; runDownloads(); return }
        activeDownload = id
        // iOS gives a few extra minutes if the app goes to the background mid-download.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Descarga") {}
        downloadTask = Task {
            defer {
                UIApplication.shared.endBackgroundTask(background)
                downloadTask = nil; activeDownload = nil
                runDownloads()
            }
            do {
                try await Self.write(file, account: account) { [weak self] value in
                    Task { @MainActor in if self?.downloadProgress[id] != nil { self?.downloadProgress[id] = value } }
                }
                downloadProgress[id] = nil
                downloadedIDs.insert(id)
            } catch {
                downloadProgress[id] = nil
                if !(error is CancellationError) && !Task.isCancelled { self.error = "No se pudo descargar: " + error.localizedDescription }
            }
        }
    }

    /// Copies the video block by block to a partial file and renames it when complete.
    private static func write(_ file: VideoFile, account: NASAccount, progress: @escaping @Sendable (Double) -> Void) async throws {
        let cache = BlockCache.shared
        let total = try await cache.length(file, account: account)
        let folder = BlockCache.downloadsFolder
        let destination = folder.appendingPathComponent(BlockCache.key(file) + "." + file.url.pathExtension.lowercased())
        let partial = folder.appendingPathComponent(BlockCache.key(file) + ".partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: partial)
        var finished = false
        defer { try? handle.close(); if !finished { try? FileManager.default.removeItem(at: partial) } }
        let blocks = (total + Int64(BlockCache.blockSize) - 1) / Int64(BlockCache.blockSize)
        for index in 0..<blocks {
            try Task.checkCancellation()
            let data = try await cache.block(index, of: file, account: account)
            guard !data.isEmpty else { throw VideoError.message("El archivo quedó incompleto.") }
            try handle.write(contentsOf: data)
            progress(Double(index + 1) / Double(blocks))
        }
        try handle.synchronize(); try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        finished = true
    }

    var downloadsSize: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: BlockCache.downloadsFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

extension AppStore {
    var durationsName: String { "durations-" + String(Files.key(account?.scope ?? "none").prefix(16)) + ".json" }

    /// Reads a music video's length once, so the grid shows it before it is played.
    func probeDuration(_ clip: MusicVideo) async {
        guard durations[clip.id] == nil, !probing.contains(clip.id), let account else { return }
        if durations.isEmpty, let saved = Files.load(durationsName, as: [String: Double].self) {
            durations = saved
            if durations[clip.id] != nil { return }
        }
        probing.insert(clip.id)
        defer { probing.remove(clip.id) }
        guard let seconds = await FrameGrabber.duration(clip.file, account: account) else { return }
        durations[clip.id] = seconds
        try? Files.save(durations, name: durationsName)
    }

    func duration(of clip: MusicVideo) -> Double? {
        durations[clip.id] ?? progress[clip.id].map(\.duration)
    }

    /// Downloaded movies, and the series that have downloaded episodes.
    var downloadedTitles: [String] {
        var ids: [String] = []
        for id in downloadedIDs.sorted() {
            let title = movie(id) != nil ? id : show(containing: id)?.id
            if let title, !ids.contains(title) { ids.append(title) }
        }
        return ids
    }
}
