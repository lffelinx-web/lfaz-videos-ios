import Foundation



enum NASConnectionMode: String, Codable, CaseIterable {

    case automatic, local, tailscale

    var label: String { switch self { case .automatic: return "Automática"; case .local: return "Local"; case .tailscale: return "Tailscale" } }

}

extension NASAccount {

    var routes: [String] {

        let remote = tailscaleHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch connectionMode ?? .automatic {

        case .local: return [routeIP]

        case .tailscale: return remote.isEmpty ? [] : [remote]

        case .automatic: return remote.isEmpty || remote == routeIP ? [routeIP] : [routeIP, remote]

        }

    }

    static func validRoute(_ value: String) -> Bool {

        if value.isEmpty { return true }

        if value.allSatisfy({ $0.isNumber || $0 == "." }) { return URLPolicy.validIPv4(value) }

        guard value.count <= 253, !value.contains(":"), !value.contains("/"), !value.contains("@") else { return false }

        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in

            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"

                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }

        }

    }

}



/// Successful routes are shared by streaming, scanning and downloads. Each success renews

/// the lease so a playing video never stalls on a LAN retry; after a minute without
/// requests LAN is tried first again, so returning home leaves the VPN.

final class NASRouteCache: @unchecked Sendable {

    static let shared = NASRouteCache()

    private let lock = NSLock()

    private var values: [String: (String, Date)] = [:]

    func ordered(_ account: NASAccount, now: Date = Date()) -> [String] {

        let routes = account.routes

        guard account.connectionMode == nil || account.connectionMode == .automatic else { return routes }

        lock.lock(); defer { lock.unlock() }

        guard let (route, date) = values[account.scope], now.timeIntervalSince(date) < 60, routes.contains(route) else { return routes }

        return [route] + routes.filter { $0 != route }

    }

    func succeeded(_ route: String, account: NASAccount, now: Date = Date()) {

        lock.lock(); defer { lock.unlock() }



        values[account.scope] = (route, now)

    }

}


enum NASRouteFallback {
    static func perform<T>(account: NASAccount, operation: (String) async throws -> T) async throws -> T {
        let routes = NASRouteCache.shared.ordered(account)
        guard !routes.isEmpty else { throw VideoError.message("Configura la dirección Tailscale del NAS.") }
        var failure: Error = URLError(.cannotConnectToHost)
        for route in routes {
            try Task.checkCancellation()
            do {
                let result = try await operation(route)
                NASRouteCache.shared.succeeded(route, account: account)
                return result
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || error is VideoError { throw error }
                failure = error
            }
        }
        throw failure
    }
}
