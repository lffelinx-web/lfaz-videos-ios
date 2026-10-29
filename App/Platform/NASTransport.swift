import Foundation

import Network

import Security

struct NASResponse {

    var route: String? = nil
    let status: Int

    let headers: [String: String]

    let data: Data

    var totalLength: Int64? {

        if let range = headers["content-range"], let tail = range.split(separator: "/").last, let total = Int64(tail) { return total }

        return headers["content-length"].flatMap(Int64.init)

    }

}

/// Connects to an optional LAN/Tailscale IP while preserving the HTTPS hostname,

/// SNI and the system trust chain. Each bounded range uses its own connection.

final class NASTransport: @unchecked Sendable {

    let account: NASAccount

    init(_ account: NASAccount) { self.account = account }

    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data = Data(), limit: Int = 2_000_000, allowPrefix: Bool = false) async throws -> NASResponse {

        try await NASRouteFallback.perform(account: account) { route in
            var response = try await requestOnRoute(url, route: route, method: method, headers: headers, body: body, limit: limit, allowPrefix: allowPrefix)
            response.route = route
            NotificationCenter.default.post(name: .nasRequestSucceeded, object: nil, userInfo: ["scope": account.scope])
            return response
        }
    }

    private func requestOnRoute(_ url: URL, route: String, method: String, headers: [String: String], body: Data, limit: Int, allowPrefix: Bool) async throws -> NASResponse {

        guard URLPolicy.allowed(url, root: account.root), ["GET", "PROPFIND"].contains(method),

              NASAccount.validRoute(route), !account.username.contains(":"),

              let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {

            throw VideoError.message("La solicitud está fuera de la carpeta autorizada.")

        }

        let tls = NWProtocolTLS.Options()

        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }

        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")

        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in

            let value = sec_trust_copy_ref(trust).takeRetainedValue()

            let policy = SecPolicyCreateSSL(true, host as CFString)

            guard SecTrustSetPolicies(value, policy) == errSecSuccess else { complete(false); return }

            complete(SecTrustEvaluateWithError(value, nil))

        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())

        let connection = NWConnection(host: NWEndpoint.Host(route.isEmpty ? host : route), port: port, using: parameters)

        let queue = DispatchQueue(label: "lfaz.https.\(UUID().uuidString)")

        let timeout = DispatchWorkItem { connection.cancel() }

        queue.asyncAfter(deadline: .now() + 35, execute: timeout)

        let connectTimeout = DispatchWorkItem { connection.cancel() }

        queue.asyncAfter(deadline: .now() + 4, execute: connectTimeout)

        defer { connectTimeout.cancel(); timeout.cancel(); connection.cancel() }

        return try await withTaskCancellationHandler(operation: {

            try Task.checkCancellation()

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in

                connection.stateUpdateHandler = { state in

                    switch state {

                    case .ready: connection.stateUpdateHandler = nil; continuation.resume()

                    case .failed(let error): connection.stateUpdateHandler = nil; continuation.resume(throwing: error)

                    case .cancelled: connection.stateUpdateHandler = nil; continuation.resume(throwing: URLError(.timedOut))

                    default: break

                    }

                }

                connection.start(queue: queue)

            }

            connectTimeout.cancel()

            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath

            let hostValue = (host.contains(":") ? "[\(host)]" : host) + (url.port.map { ":\($0)" } ?? "")

            let credential = Data("\(account.username):\(account.password)".utf8).base64EncodedString()

            var lines = ["\(method) \(path.isEmpty ? "/" : path) HTTP/1.1", "Host: \(hostValue)", "Authorization: Basic \(credential)", "Connection: close", "Accept-Encoding: identity", "Content-Length: \(body.count)"]

            for (key, value) in headers {

                guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else { throw VideoError.message("Cabecera no válida.") }

                lines.append("\(key): \(value)")

            }

            var wire = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8); wire.append(body)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in

                connection.send(content: wire, completion: .contentProcessed { error in

                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }

                })

            }

            let reader = SocketReader(connection)

            let head = try await reader.until(Data("\r\n\r\n".utf8), max: 65536)

            guard let text = String(data: head, encoding: .isoLatin1), let first = text.components(separatedBy: "\r\n").first,

                  let status = Int(first.split(separator: " ").dropFirst().first ?? ""), (200...299).contains(status) else {

                let statusLine = String(data: head.prefix(100), encoding: .isoLatin1) ?? ""

                if statusLine.contains("401") { throw VideoError.message("Usuario o contraseña incorrectos.") }

                if statusLine.contains("403") { throw VideoError.message("La cuenta no tiene permiso de lectura.") }

                throw VideoError.message("El NAS rechazó la solicitud. Revisa la carpeta y el acceso WebDAV; no se siguen redirecciones.")

            }

            var fields: [String: String] = [:]

            for line in text.components(separatedBy: "\r\n").dropFirst() {

                if let colon = line.firstIndex(of: ":") {

                    fields[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

                }

            }

            if let encoding = fields["content-encoding"], encoding != "identity" { throw VideoError.message("El NAS envió una codificación no compatible.") }

            var result = Data()

            func append(_ part: Data) throws -> Bool {

                if result.count + part.count > limit {

                    guard allowPrefix else { throw VideoError.message("La respuesta excede el tamaño permitido.") }

                    result.append(part.prefix(limit - result.count)); return false

                }

                result.append(part); return !allowPrefix || result.count < limit

            }

            if fields["transfer-encoding"]?.lowercased() == "chunked" {

                outer: while true {

                    let line = try await reader.until(Data("\r\n".utf8), max: 4096)

                    guard let text = String(data: line, encoding: .ascii), let number = text.split(separator: ";").first,

                          let size = Int(number, radix: 16), size >= 0 else { throw VideoError.message("Respuesta HTTP incompleta.") }

                    if size == 0 { break }

                    var remaining = size

                    while remaining > 0 {

                        let part = try await reader.exactly(min(65536, remaining)); remaining -= part.count

                        if try !append(part) { break outer }

                    }

                    guard try await reader.exactly(2) == Data("\r\n".utf8) else { throw VideoError.message("Respuesta HTTP no válida.") }

                }

            } else if let text = fields["content-length"], let size = Int64(text), size >= 0 {

                if size > Int64(limit) && !allowPrefix { throw VideoError.message("La respuesta excede el tamaño permitido.") }

                var remaining = size

                while remaining > 0 {

                    let part = try await reader.exactly(Int(min(65536, remaining))); remaining -= Int64(part.count)

                    if try !append(part) { break }

                }

            } else {

                while let part = try await reader.some() { if try !append(part) { break } }

            }

            try Task.checkCancellation()

            return NASResponse(status: status, headers: fields, data: result)

        }, onCancel: { connection.cancel() })

    }

    func list(_ folder: URL) async throws -> [DAVEntry] {

        let xml = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>".utf8)

        let response = try await request(folder, method: "PROPFIND", headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"], body: xml)

        guard response.status == 207 else { throw VideoError.message("La dirección no corresponde a WebDAV.") }

        return try DAVParser.parse(response.data, folder: folder)

    }

    func range(_ url: URL, start: Int64, count: Int, prefix: Bool = false) async throws -> NASResponse {

        let response = try await request(url, headers: ["Range": "bytes=\(start)-\(start + Int64(count) - 1)"], limit: count, allowPrefix: prefix)

        if response.status == 206 {

            guard response.headers["content-range"]?.hasPrefix("bytes \(start)-") == true else { throw VideoError.message("El NAS devolvió un rango de video incorrecto.") }

        } else if start != 0 { throw VideoError.message("El NAS no permite avanzar dentro del video.") }

        return response

    }

}

private final class SocketReader {

    let connection: NWConnection

    var buffer = Data()

    var ended = false

    init(_ connection: NWConnection) { self.connection = connection }

    func receive() async throws {

        try Task.checkCancellation()

        if ended { throw VideoError.message("La conexión se interrumpió antes de completar el archivo.") }

        let pair: (Data, Bool) = try await withCheckedThrowingContinuation { continuation in

            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in

                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), complete)) }

            }

        }

        buffer.append(pair.0); ended = pair.1

    }

    func until(_ delimiter: Data, max: Int) async throws -> Data {

        while true {

            if let range = buffer.range(of: delimiter) {

                guard range.lowerBound <= max else { throw VideoError.message("Cabecera HTTP demasiado grande.") }

                let result = Data(buffer[..<range.lowerBound]); buffer = Data(buffer[range.upperBound...]); return result

            }

            if buffer.count > max { throw VideoError.message("Cabecera HTTP demasiado grande.") }

            try await receive()

        }

    }

    func exactly(_ count: Int) async throws -> Data {

        while buffer.count < count { try await receive() }

        let result = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return result

    }

    func some() async throws -> Data? {

        if buffer.isEmpty && !ended { try await receive() }

        if buffer.isEmpty { return nil }

        let result = buffer; buffer = Data(); return result

    }

}


extension Notification.Name {
    static let nasRequestSucceeded = Notification.Name("lfaz.videos.nas.request.succeeded")
}
