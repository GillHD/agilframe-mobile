import Foundation

/**
 * Pure, WebKit-free canonicalisation of `scheme://host[:port]` origins.
 *
 * `WKSecurityOrigin.port` is **0** when the page uses the scheme's default port
 * (WebKit/Chromium normalise `https://host` and `https://host:443` to port `0`
 * there). A URL parsed from a string usually omits the port instead. Both must
 * produce the same canonical origin (`https://host`); otherwise every
 * `agil:*` message from a normal HTTPS widget fails the bridge origin check.
 *
 * This file deliberately imports only Foundation so an Xcode test target can
 * compile and run it without a simulator. It must stay free of WebKit/UIKit.
 */
enum AgilOriginNormalizer {
    /// Canonical `scheme://host[:port]` for a URL string.
    ///
    /// Returns `nil` for non-http(s) schemes, credentials, malformed values and
    /// an explicit port `0` (not a usable HTTP endpoint).
    static func normalize(urlString: String) -> String? {
        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            components.user == nil,
            components.password == nil,
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            return nil
        }
        if let port = components.port {
            guard port > 0 else { return nil }
            return normalize(scheme: scheme, host: host, port: port)
        }
        return normalize(scheme: scheme, host: host, port: nil)
    }

    /// Canonical origin for a scheme/host/port triple.
    ///
    /// - `port == nil`: the URL did not specify a port, i.e. the scheme default.
    /// - `port == 0`: WebKit's "effective default port" (`WKSecurityOrigin`).
    ///
    /// Any other explicit port is preserved, so `https://host:8443` never
    /// matches `https://host`. Default-port normalisation is the only
    /// equivalence applied; the scheme and host must match exactly.
    static func normalize(scheme: String?, host: String?, port: Int?) -> String? {
        guard
            let scheme = scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = host?.lowercased(),
            !host.isEmpty,
            !host.contains("/"),
            !host.contains("@"),
            !host.contains("\\")
        else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let requestedPort = port ?? 0
        let effectivePort = requestedPort == 0 ? defaultPort : requestedPort
        guard effectivePort > 0, effectivePort <= 65_535 else { return nil }
        if effectivePort == defaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(effectivePort)"
    }

    /// Convenience wrapper for `WKSecurityOrigin`, where port `0` means the
    /// scheme default. Kept separate so the controller reads explicitly.
    static func normalize(securityScheme: String, host: String, port: Int) -> String? {
        normalize(scheme: securityScheme, host: host, port: port)
    }
}
