import Foundation

/// Video bytes in aligned 1 MB blocks: from a finished download, from the temporary cache,
/// or from the NAS (and then kept in the cache). Rewinding replays from disk.
actor BlockCache {
    static let shared = BlockCache()
    static let blockSize = 1_048_576

    private var limit: Int64 = 2_048 * 1_048_576
    private var lengths: [String: Int64] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var writesSinceTrim = 0

    nonisolated static func key(_ file: VideoFile) -> String { Files.key(file.url.absoluteString) }

    nonisolated static var downloadsFolder: URL {
        let url = Files.root.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = url; try? mutable.setResourceValues(values)
        return url
    }

    private nonisolated static var cacheFolder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Stream", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func downloaded(_ file: VideoFile) -> URL? {
        let url = downloadsFolder.appendingPathComponent(key(file) + "." + file.url.pathExtension.lowercased())
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func configure(megabytes: Int) { limit = Int64(max(256, megabytes)) * 1_048_576; trim() }

    func length(_ file: VideoFile, account: NASAccount?) async throws -> Int64 {
        if let local = Self.downloaded(file), let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize { return Int64(size) }
        let key = Self.key(file)
        if let known = lengths[key] { return known }
        guard let account else { throw VideoError.message("Conecta el NAS para ver este video.") }
        let response = try await NASTransport(account).range(file.url, start: 0, count: 1, prefix: true)
        guard let total = response.totalLength ?? file.bytes, total > 0 else { throw VideoError.message("No se pudo conocer el tamaño del video.") }
        lengths[key] = total
        return total
    }

    /// One aligned block; concurrent requests for the same block share a single NAS fetch.
    func block(_ index: Int64, of file: VideoFile, account: NASAccount?) async throws -> Data {
        let start = index * Int64(Self.blockSize)
        if let local = Self.downloaded(file) {
            let handle = try FileHandle(forReadingFrom: local); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            return try handle.read(upToCount: Self.blockSize) ?? Data()
        }
        let key = Self.key(file)
        let path = Self.cacheFolder.appendingPathComponent("\(key)-\(index).blk")
        if let data = try? Data(contentsOf: path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            return data
        }
        let taskKey = "\(key)-\(index)"
        if let running = inFlight[taskKey] { return try await running.value }
        let total = try await length(file, account: account)
        guard start < total else { return Data() }
        guard let account else { throw VideoError.message("Esta parte del video no está guardada. Conecta el NAS.") }
        let count = Int(min(Int64(Self.blockSize), total - start))
        let task = Task { try await NASTransport(account).range(file.url, start: start, count: count).data }
        inFlight[taskKey] = task
        defer { inFlight[taskKey] = nil }
        let data = try await task.value
        guard data.count == count else { throw VideoError.message("El bloque del video llegó incompleto.") }
        try? data.write(to: path, options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= 32 { writesSinceTrim = 0; trim() }
        return data
    }

    /// Whether every block of the file is already on the phone.
    func isComplete(_ file: VideoFile, account: NASAccount?) async -> Bool {
        if Self.downloaded(file) != nil { return true }
        guard let total = try? await length(file, account: account) else { return false }
        let key = Self.key(file), blocks = (total + Int64(Self.blockSize) - 1) / Int64(Self.blockSize)
        return (0..<blocks).allSatisfy { FileManager.default.fileExists(atPath: Self.cacheFolder.appendingPathComponent("\(key)-\($0).blk").path) }
    }

    /// Size of the temporary cache, in bytes.
    func cacheSize() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.cacheFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheFolder)
        _ = Self.cacheFolder
    }

    /// Oldest blocks go first once the cache passes its limit.
    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.cacheFolder, includingPropertiesForKeys: keys) else { return }
        var entries = urls.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { total -= entry.1 }
        }
    }
}
