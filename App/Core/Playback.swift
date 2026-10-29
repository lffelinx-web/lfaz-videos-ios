import Foundation

/// What the player needs to open one movie, episode or music video.
struct PlaybackRequest: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var file: VideoFile
    var start: Double = 0
}

struct WatchProgress: Codable, Equatable {
    var position: Double
    var duration: Double
    var updated: Date
    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    /// Credits usually start in the last minutes: treat 95% as watched.
    var finished: Bool { fraction >= 0.95 }
    var resumable: Bool { position >= 30 && !finished }
    var remaining: Double { max(0, duration - position) }
}

func remainingText(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded(.up))
    if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min restantes" }
    return "\(max(1, minutes)) min restantes"
}

func clockText(_ seconds: Double) -> String {
    let total = seconds.isFinite ? Int(max(0, seconds)) : 0
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// A parsed `Range: bytes=…` header, resolved against the file length (both ends inclusive).
struct ByteRange: Equatable {
    var start: Int64
    var end: Int64
    var count: Int64 { end - start + 1 }

    /// `nil` means the range can't be satisfied (416); a missing or malformed header means the whole file.
    static func parse(_ header: String?, total: Int64) -> ByteRange? {
        guard total > 0 else { return nil }
        let whole = ByteRange(start: 0, end: total - 1)
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return whole }
        // Players ask for one range at a time; only the first of a list is honoured.
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return whole }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return ByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(parts[0]), start >= 0 else { return whole }
        guard start < total else { return nil }
        let end = parts[1].isEmpty ? total - 1 : min(Int64(parts[1]) ?? total - 1, total - 1)
        return end >= start ? ByteRange(start: start, end: end) : nil
    }
}

enum MediaType {
    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }
}
