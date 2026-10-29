import Foundation

/// Reads titles, years, seasons and episodes from the names used on the NAS:
/// `Interstellar (2014).mkv`, `Serie/Temporada 1/Serie S01E01.mkv`, `Videos/Pop/Artista - Título.mp4`.
enum MediaNaming {
    struct MovieName: Equatable { var title: String; var year: Int?; var tags: [String] }
    struct EpisodeName: Equatable { var season: Int?; var number: Int; var lastNumber: Int?; var title: String? }
    struct ClipName: Equatable { var title: String; var artist: String }

    static func movie(_ fileName: String) -> MovieName {
        let base = stripExtension(fileName)
        let tags = qualityTags(base)
        var text = removeBrackets(base, keepingYear: true)
        var year: Int?
        if let match = lastMatch(#"(?:^|[\s._(\[-])((?:19|20)\d{2})(?=$|[\s._)\]-])"#, in: text), match.range(at: 1).location > 0 {
            let ns = text as NSString
            let value = Int(ns.substring(with: match.range(at: 1))) ?? 0
            // `Blade Runner 2049` is a title, not a release year.
            if value <= Calendar.current.component(.year, from: Date()) + 1 {
                year = value
                text = ns.substring(to: match.range.location)
            }
        }
        let title = cleanTitle(cutAtJunk(text))
        return MovieName(title: title.isEmpty ? cleanTitle(text) : title, year: year, tags: tags)
    }

    static func episode(_ fileName: String) -> EpisodeName? {
        let base = stripExtension(fileName)
        let ns = base as NSString
        let patterns = [
            #"[Ss](\d{1,2})[\s._-]*[Ee](\d{1,3})(?:[\s._-]*-?[\s._-]*[Ee](\d{1,3}))?"#,
            #"(?:^|[\s._-])(\d{1,2})[xX](\d{1,3})(?:-(\d{1,3}))?(?=$|[\s._-])"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: base) else { continue }
            let season = Int(ns.substring(with: match.range(at: 1)))
            guard let number = Int(ns.substring(with: match.range(at: 2))) else { continue }
            let last = match.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 3)))
            let tail = ns.substring(from: match.range.location + match.range.length)
            return EpisodeName(season: season, number: number, lastNumber: last.flatMap { $0 > number ? $0 : nil }, title: episodeTitle(tail))
        }
        let words = #"(?i)(?:^|[\s._-])(?:episodio|episode|capitulo|capítulo|cap|ep)[\s._-]*(\d{1,3})(?=$|[\s._-])"#
        if let match = firstMatch(words, in: base), let number = Int(ns.substring(with: match.range(at: 1))) {
            return EpisodeName(season: nil, number: number, lastNumber: nil, title: episodeTitle(ns.substring(from: match.range.location + match.range.length)))
        }
        if let match = firstMatch(#"^(\d{1,3})(?=$|[\s._-])"#, in: base), let number = Int(ns.substring(with: match.range(at: 1))) {
            return EpisodeName(season: nil, number: number, lastNumber: nil, title: episodeTitle(ns.substring(from: match.range.length)))
        }
        return nil
    }

    /// `Temporada 1`, `Season 01`, `S2`, `T3`; `Especiales` and `Specials` are season 0.
    static func season(_ folderName: String) -> Int? {
        let key = folderName.searchKey
        if ["especiales", "specials", "extras"].contains(key) { return 0 }
        guard let match = firstMatch(#"^(?:temporada|season|temp|s|t)[\s._-]*(\d{1,2})$"#, in: key) else { return nil }
        return Int((key as NSString).substring(with: match.range(at: 1)))
    }

    static func show(_ folderName: String) -> (title: String, year: Int?) {
        let parsed = movie(folderName + ".folder")
        return (parsed.title.isEmpty ? folderName : parsed.title, parsed.year)
    }

    /// `Breaking Bad S01E01.mkv` stored directly in `Series/` → `Breaking Bad`.
    static func showTitle(fromEpisode fileName: String) -> String? {
        let base = stripExtension(fileName)
        guard let match = firstMatch(#"[Ss]\d{1,2}[\s._-]*[Ee]\d{1,3}|(?:^|[\s._-])\d{1,2}[xX]\d{1,3}(?=$|[\s._-])"#, in: base), match.range.location > 0 else { return nil }
        let title = show((base as NSString).substring(to: match.range.location)).title
        return title.isEmpty ? nil : title
    }

    static func clip(_ fileName: String) -> ClipName {
        var text = stripExtension(fileName)
        text = replace(#"\s*[\(\[][^\)\]]*(?:official|oficial|video|vídeo|audio|lyric|letra|4k|hd|remaster)[^\)\]]*[\)\]]"#, in: text, with: "", options: [.caseInsensitive])
        let parts = text.components(separatedBy: " - ")
        if parts.count >= 2 {
            return ClipName(title: cleanTitle(parts.dropFirst().joined(separator: " - ")), artist: cleanTitle(parts[0]))
        }
        return ClipName(title: cleanTitle(text), artist: "Artista desconocido")
    }

    static func qualityTags(_ text: String) -> [String] {
        let key = " " + text.lowercased().replacingOccurrences(of: #"[._\[\]\(\)-]"#, with: " ", options: .regularExpression) + " "
        var tags: [String] = []
        if key.contains(" 2160p ") || key.contains(" 4k ") || key.contains(" uhd ") { tags.append("4K") }
        else if key.contains(" 1080p ") { tags.append("1080p") }
        else if key.contains(" 720p ") { tags.append("720p") }
        if key.range(of: #" hdr(10)?\+? "#, options: .regularExpression) != nil { tags.append("HDR") }
        if key.contains(" dv ") || key.contains(" dolby vision ") || key.contains(" dovi ") { tags.append("Dolby Vision") }
        if key.contains(" atmos ") { tags.append("Dolby Atmos") }
        return tags
    }

    // MARK: Helpers

    private static let junk = #"(?i)(?:^|[\s._-])(?:2160p|1080p|720p|480p|4k|uhd|hdr10\+?|hdr|dv|bluray|blu-ray|brrip|bdrip|webrip|web-dl|webdl|web|hdtv|dvdrip|remux|x264|x265|h264|h265|hevc|avc|aac|ac3|dts|atmos|10bit|proper|repack|extended|unrated|latino|castellano|dual|multi|subs?)(?=$|[\s._-])"#

    private static func cutAtJunk(_ text: String) -> String {
        guard let match = firstMatch(junk, in: text) else { return text }
        return (text as NSString).substring(to: match.range.location)
    }

    private static func episodeTitle(_ tail: String) -> String? {
        let title = cleanTitle(cutAtJunk(removeBrackets(tail, keepingYear: false)))
        return title.isEmpty ? nil : title
    }

    private static func stripExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || ext.count > 6 || ext.contains(" ") ? name : (name as NSString).deletingPathExtension
    }

    private static func removeBrackets(_ text: String, keepingYear: Bool) -> String {
        let pattern = keepingYear ? #"\[[^\]]*\]|\{[^\}]*\}|\((?!(?:19|20)\d{2}\))[^\)]*\)"# : #"\[[^\]]*\]|\{[^\}]*\}|\([^\)]*\)"#
        return replace(pattern, in: text, with: " ")
    }

    static func cleanTitle(_ text: String) -> String {
        var value = text
        let separators = CharacterSet(charactersIn: "._")
        if !value.contains(" ") || value.unicodeScalars.filter({ separators.contains($0) }).count >= 2 {
            value = replace(#"(?<=\S)[._](?=\S)"#, in: value, with: " ")
            value = value.replacingOccurrences(of: "_", with: " ")
        }
        value = value.replacingOccurrences(of: "()", with: "")
        value = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " -–—.,_:"))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func lastMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last
    }

    private static func replace(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
