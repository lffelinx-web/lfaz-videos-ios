import Foundation
import Network

/// A loopback HTTP server that hands NAS videos to AVPlayer and VLC.
///
/// Neither player can use `NASTransport` (LAN/Tailscale IP with the HTTPS hostname
/// as SNI), so they read `http://127.0.0.1:<port>/v/<token>.<ext>` and this server
/// answers each byte range by fetching it from the NAS in blocks.
final class StreamServer: @unchecked Sendable {
    static let shared = StreamServer()
    static let blockSize = 2 * 1_048_576
    /// A small first block lets playback start before a full block arrives over Tailscale.
    static let firstBlockSize = 512 * 1024
    static let prefetch = 2

    private let queue = DispatchQueue(label: "lfaz.stream.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var items: [String: (file: VideoFile, account: NASAccount)] = [:]
    private var lengths: [URL: Int64] = [:]

    func url(for file: VideoFile, account: NASAccount) async throws -> URL {
        let port = try await start()
        let token = UUID().uuidString
        lock.withLock { items[token] = (file, account) }
        let ext = file.url.pathExtension.lowercased()
        return URL(string: "http://127.0.0.1:\(port)/v/\(token)" + (ext.isEmpty ? "" : ".\(ext)"))!
    }

    private func start() async throws -> UInt16 {
        if let current = lock.withLock({ self.listener != nil && self.port != 0 ? self.port : nil }) { return current }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: listener?.port?.rawValue ?? 0) }
                case .failed(let error):
                    self?.reset()
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                case .cancelled:
                    self?.reset()
                    if !resumed { resumed = true; continuation.resume(throwing: VideoError.message("No se pudo iniciar el reproductor.")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener; self.port = port }
        return port
    }

    /// iOS may close the socket in the background; the next request starts a new listener.
    private func reset() { lock.withLock { listener = nil; port = 0 } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { await self.handle(connection); connection.cancel() }
    }

    private func handle(_ connection: NWConnection) async {
        guard let head = try? await receiveHead(connection),
              let lines = String(data: head, encoding: .isoLatin1)?.components(separatedBy: "\r\n"),
              let first = lines.first?.split(separator: " "), first.count >= 2 else { return }
        let method = String(first[0]), path = String(first[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let token = ((path.split(separator: "/").last.map(String.init) ?? "") as NSString).deletingPathExtension
        guard ["GET", "HEAD"].contains(method), let item = lock.withLock({ items[token] }) else {
            try? await send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        let transport = NASTransport(item.account)
        do {
            let total = try await length(of: item.file, transport: transport)
            let mime = MediaType.mime(item.file.url.pathExtension)
            guard let range = ByteRange.parse(headers["range"], total: total) else {
                try await send(connection, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            }
            let partial = headers["range"] != nil
            var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            response += "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nConnection: close\r\n"
            if partial { response += "Content-Range: bytes \(range.start)-\(range.end)/\(total)\r\n" }
            try await send(connection, Data((response + "\r\n").utf8))
            guard method == "GET" else { return }

            // Keep two blocks in flight so each NAS round trip overlaps with writing to the player.
            var next = range.start
            var pending: [Task<Data, Error>] = []
            func schedule() {
                while pending.count < Self.prefetch && next <= range.end {
                    let start = next, first = start == range.start
                    let size = Int(min(Int64(first ? Self.firstBlockSize : Self.blockSize), range.end - start + 1))
                    pending.append(Task { try await transport.range(item.file.url, start: start, count: size).data })
                    next += Int64(size)
                }
            }
            defer { pending.forEach { $0.cancel() } }
            schedule()
            while !pending.isEmpty {
                let data = try await pending.removeFirst().value
                guard !data.isEmpty else { return }
                schedule()
                try await send(connection, data)
            }
        } catch {
            // The player closed the connection (seek or stop) or the NAS failed; the player retries with a new range.
        }
    }

    private func length(of file: VideoFile, transport: NASTransport) async throws -> Int64 {
        if let known = lock.withLock({ lengths[file.url] }) { return known }
        let response = try await transport.range(file.url, start: 0, count: 1, prefix: true)
        guard let total = response.totalLength ?? file.bytes, total > 0 else { throw VideoError.message("No se pudo conocer el tamaño del video.") }
        lock.withLock { lengths[file.url] = total }
        return total
    }

    private func receiveHead(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 16_384 else { throw VideoError.message("Solicitud demasiado grande.") }
            let (data, complete): (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), complete)) }
                }
            }
            buffer.append(data)
            if complete && buffer.range(of: Data("\r\n\r\n".utf8)) == nil { throw VideoError.message("Solicitud incompleta.") }
        }
        return buffer
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
