import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum URLPolicy {
    static func root(_ text: String) throws -> URL {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!) else {
            throw VideoError.message("Introduce una dirección HTTPS, sin usuario ni parámetros.")
        }
        if !c.path.hasSuffix("/") { c.path += "/" }
        guard let url = c.url, safePath(url) else { throw VideoError.message("La ruta de la carpeta no es válida.") }
        return url
    }
    static func safePath(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            guard let s = String($0).removingPercentEncoding else { return false }
            return s != ".." && s != "." && !s.contains("/") && !s.contains("\\") && !s.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        }
    }
    static func allowed(_ url: URL, root: URL) -> Bool {
        guard let u = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let r = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return false }
        return u.scheme == "https" && u.host?.lowercased() == r.host?.lowercased() && (u.port ?? 443) == (r.port ?? 443) &&
            u.user == nil && u.password == nil && u.query == nil && u.fragment == nil && safePath(url) &&
            u.percentEncodedPath.hasPrefix(r.percentEncodedPath)
    }
    static func validIPv4(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }
}

struct DAVEntry {
    var url: URL
    var name: String
    var directory: Bool
    var bytes: Int64?
    var modified: Date? = nil
    var video: Bool { !directory && VideoFormat.supported.contains(url.pathExtension.lowercased()) }
    var image: Bool { !directory && ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) }
}

final class DAVParser: NSObject, XMLParserDelegate {
    private let folder: URL
    private var names: [String] = []
    private var buffer = ""
    private var href = "", display = "", status = "", length: Int64?, modified: Date?
    private var directory = false, valid = false, propertyDirectory = false
    private var propertyDisplay = "", propertyLength: Int64?, propertyModified: Date?
    private var multistatus = false
    private var entries: [DAVEntry] = []
    init(folder: URL) { self.folder = folder }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    static func httpDate(_ text: String) -> Date? { dateFormatter.date(from: text) }
    static func parse(_ data: Data, folder: URL) throws -> [DAVEntry] {
        guard data.count <= 2_000_000, let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<!\\s*(DOCTYPE|ENTITY)", options: [.regularExpression, .caseInsensitive]) == nil else {
            throw VideoError.message("Respuesta WebDAV demasiado grande o XML no permitido.")
        }
        let delegate = DAVParser(folder: folder)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.multistatus else { throw VideoError.message("La respuesta no es un catálogo WebDAV válido.") }
        var seen = Set<URL>()
        return delegate.entries.filter { seen.insert($0.url).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        names.append(namespaceURI == "DAV:" ? elementName : "_"); buffer = ""
        if names.count == 1 { multistatus = namespaceURI == "DAV:" && elementName == "multistatus" }
        guard namespaceURI == "DAV:" else { return }
        if elementName == "response" { href = ""; display = ""; length = nil; modified = nil; directory = false; valid = false }
        if elementName == "propstat" { status = ""; propertyDisplay = ""; propertyLength = nil; propertyModified = nil; propertyDirectory = false }
        if elementName == "collection" { propertyDirectory = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if !names.isEmpty { names.removeLast() }; buffer = "" }
        guard namespaceURI == "DAV:" else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": href = value
        case "displayname": propertyDisplay = value
        case "getcontentlength": propertyLength = Int64(value).flatMap { $0 >= 0 ? $0 : nil }
        case "getlastmodified": propertyModified = DAVParser.httpDate(value)
        case "status": status = value
        case "propstat":
            if status.range(of: "HTTP/\\S+\\s+200(?:\\s|$)", options: .regularExpression) != nil {
                valid = true; directory = directory || propertyDirectory
                if !propertyDisplay.isEmpty { display = propertyDisplay }; if let n = propertyLength { length = n }; if let d = propertyModified { modified = d }
            }
        case "response":
            guard valid, !href.isEmpty, let url = URL(string: href, relativeTo: folder)?.absoluteURL, URLPolicy.allowed(url, root: folder),
                  let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                  let base = URLComponents(url: folder, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return }
            let tail = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !tail.isEmpty, !tail.contains("/") else { return }
            let canonical = directory && !url.absoluteString.hasSuffix("/") ? URL(string: url.absoluteString + "/")! : url
            entries.append(DAVEntry(url: canonical, name: display.isEmpty ? url.lastPathComponent : display, directory: directory, bytes: length, modified: modified))
        default: break
        }
    }
}
