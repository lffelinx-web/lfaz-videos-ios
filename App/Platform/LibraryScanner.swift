import Foundation

/// Walks the `Películas`, `Series` and `Videos` folders under the WebDAV root and builds the library.
struct LibraryScanner {
    static let maxDepth = 4
    static let maxFolders = 5000
    static let maxFiles = 50000

    let account: NASAccount

    func scan(progress: @escaping @Sendable (String) -> Void) async throws -> Library {
        let transport = NASTransport(account)
        let top = try await transport.list(account.root).filter(\.directory)
        var sections = Self.sectionFolders(top)
        // Also accept one wrapper level, such as `/video/Multimedia/Películas`.
        if sections.isEmpty {
            for parent in top.prefix(20) where LibrarySection.matching(folder: parent.name) == nil && !parent.name.hasPrefix("@") && !parent.name.hasPrefix("#") {
                try Task.checkCancellation()
                sections = Self.sectionFolders(try await transport.list(parent.url).filter(\.directory))
                if !sections.isEmpty { break }
            }
        }
        guard !sections.isEmpty else {
            let names = top.map(\.name).filter { !$0.hasPrefix("@") && !$0.hasPrefix("#") }
            let found = names.isEmpty ? "La carpeta está vacía." : "Carpetas encontradas: " + names.prefix(12).joined(separator: ", ") + (names.count > 12 ? "…" : ".")
            throw VideoError.message("No se encontraron las carpetas Películas, Series ni Videos en \(account.root.path). \(found) Renómbralas o corrige la dirección en Ajustes.")
        }
        var files: [ScannedFile] = [], visited = 0
        for (section, folder) in sections.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var pending: [(URL, [String])] = [(folder.url, [])]
            while let next = pending.popLast() {
                let (url, folders) = next
                try Task.checkCancellation()
                visited += 1
                guard visited <= Self.maxFolders else { throw VideoError.message("La biblioteca supera el límite de \(Self.maxFolders) carpetas.") }
                progress("\(section.title): \(folders.last ?? folder.name)")
                for entry in try await transport.list(url) {
                    if entry.directory {
                        if folders.count < Self.maxDepth { pending.append((entry.url, folders + [entry.name])) }
                    } else if entry.video || (section == .videos && entry.image) {
                        guard files.count < Self.maxFiles else { throw VideoError.message("La biblioteca supera el límite de \(Self.maxFiles) archivos.") }
                        files.append(ScannedFile(section: section, folders: folders, name: entry.name, url: entry.url, bytes: entry.bytes, modified: entry.modified))
                    }
                }
            }
        }
        return LibraryBuilder.build(files, missing: LibrarySection.allCases.filter { sections[$0] == nil })
    }

    /// The first folder that matches each section.
    static func sectionFolders(_ entries: [DAVEntry]) -> [LibrarySection: DAVEntry] {
        var result: [LibrarySection: DAVEntry] = [:]
        for entry in entries { if let section = LibrarySection.matching(folder: entry.name), result[section] == nil { result[section] = entry } }
        return result
    }
}
