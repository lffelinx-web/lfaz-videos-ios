import Foundation
import Network

/// A loopback HTTP server that hands NAS videos to AVPlayer and VLC.
///
/// Neither player can use `NASTransport` (LAN/Tailscale IP with the HTTPS hostname
/// as SNI), so they read `http://127.0.0.1:<port>/v/<token>.<ext>` and this server
/// answers each byte range by fetching it from the NAS in blocks.
final class StreamServer: @unchecked Sendable {
    static let shared = StreamServer()

    /// Blocks requested ahead of the one being written to the player.
    static let prefetch = 3

    private let queue = DispatchQueue(label: "lfaz.stream.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var items: [String: (file: VideoFile, account: NASAccount)] = [:]

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
        do {
            let cache = BlockCache.shared, file = item.file, account = item.account
            let total = try await cache.length(file, account: account)
            let mime = MediaType.mime(file.url.pathExtension)
            guard let range = ByteRange.parse(headers["range"], total: total) else {
                try await send(connection, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            }
            let partial = headers["range"] != nil
            var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            response += "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nConnection: close\r\n"
            if partial { response += "Content-Range: bytes \(range.start)-\(range.end)/\(total)\r\n" }
            try await send(connection, Data((response + "\r\n").utf8))
            guard method == "GET" else { return }

            // Whole aligned blocks come from BlockCache (disk or NAS); keep the next ones
            // in flight so each NAS round trip overlaps with writing to the player.
            let size = Int64(BlockCache.blockSize)
            let first = range.start / size, last = range.end / size
            var next = first
            var pending: [(index: Int64, task: Task<Data, Error>)] = []
            func schedule() {
                while pending.count < Self.prefetch && next <= last {
                    let index = next
                    pending.append((index, Task { try await cache.block(index, of: file, account: account) }))
                    next += 1
                }
            }
            defer { pending.forEach { $0.task.cancel() } }
            schedule()
            while !pending.isEmpty {
                let (index, task) = pending.removeFirst()
                let data = try await task.value
                guard !data.isEmpty else { return }
                schedule()
                let blockStart = index * size
                let from = Int(max(range.start, blockStart) - blockStart)
                let to = Int(min(range.end + 1, blockStart + Int64(data.count)) - blockStart)
                guard from < to else { return }
                try await send(connection, data.subdata(in: from..<to))
            }
        } catch {
            // The player closed the connection (seek or stop) or the NAS failed; the player retries with a new range.
        }
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
