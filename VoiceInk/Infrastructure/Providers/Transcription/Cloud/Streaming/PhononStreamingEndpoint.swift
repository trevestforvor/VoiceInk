import Foundation

/// This MVP is opt-in and loopback-only; it never discovers or contacts another host.
enum PhononStreamingEndpoint {
    static func url(for endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.hasSuffix("/v1/audio/transcriptions")
        else { return nil }

        if let port = components.port, !(1...65_535).contains(port) { return nil }
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = String(components.path.dropLast("transcriptions".count)) + "stream"
        return components.url
    }
}
