import Foundation

/// Builds the hosted `/embed.html` URL and enforces the navigation allowlist.
///
/// This is the only place allowed to turn configuration into a URL:
///  - `server` is the normalized base URL (subpaths preserved);
///  - every value is percent-encoded as a UTF-8 query value;
///  - `identity_token` is part of the documented embed contract and therefore
///    travels in the page URL (short-lived, never logged);
///  - the resolved page must stay on ``AgilCallConfiguration/widgetOrigin``;
///  - no `targetOrigin = "*"` is ever produced here (the WebView bridge always
///    uses the exact page origin).
enum AgilWidgetURL {
    /// Characters left unescaped in query values. Deliberately stricter than
    /// Foundation's `urlQueryAllowed`: `+` must be `%2B` so servers that decode
    /// `+` as a space cannot corrupt a token.
    private static let queryValueAllowed: CharacterSet = {
        return CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
    }()

    /// Builds a validated widget URL. Throws only for configurations that passed
    /// validation but cannot be represented as a URL (defensive).
    static func build(_ configuration: AgilCallConfiguration) throws -> URL {
        let server = configuration.normalizedServerURL
        let resolved: String
        if configuration.widgetPath.hasPrefix("/") {
            resolved = configuration.widgetOrigin + configuration.widgetPath
        } else {
            resolved = server + "/" + configuration.widgetPath
        }
        guard var components = URLComponents(string: resolved) else {
            throw AgilConfigurationError(field: .widgetPath, reason: .invalidValue)
        }

        var pairs: [(String, String)] = [
            ("server", server),
            ("room", configuration.roomId)
        ]
        if let joinToken = configuration.joinToken {
            pairs.append(("token", joinToken))
        }
        pairs.append(("tenant", configuration.tenantId))
        if let language = configuration.language {
            pairs.append(("lang", language))
        }
        if let name = configuration.participantName {
            pairs.append(("name", name))
        }
        if let identityToken = configuration.identityToken {
            pairs.append(("identity_token", identityToken))
        }
        if let theme = configuration.theme {
            pairs.append(("theme", theme.rawValue))
        }
        if configuration.relayOnly {
            pairs.append(("relay", "1"))
        }

        components.percentEncodedQuery = pairs
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .joined(separator: "&")

        guard let url = components.url else {
            throw AgilConfigurationError(field: .widgetPath, reason: .invalidValue)
        }
        guard AgilValidation.origin(of: url) == configuration.widgetOrigin else {
            throw AgilConfigurationError(field: .widgetPath, reason: .escapeFromServerOrigin)
        }
        return url
    }

    /// Navigation guard: only `about:blank`, `about:srcdoc` and http(s) URLs on
    /// an allowlisted exact origin may load. Plain HTTP is accepted only for
    /// loopback hosts or when the explicit development flag is set; credentials
    /// never match.
    static func isAllowedNavigation(
        _ url: URL,
        allowedOrigins: Set<String>,
        allowsInsecureHTTP: Bool = false
    ) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" {
            let value = url.absoluteString.lowercased()
            return value == "about:blank" || value == "about:srcdoc"
        }
        guard scheme == "https" || scheme == "http" else {
            return false
        }
        if scheme == "http",
           !allowsInsecureHTTP,
           !AgilValidation.isLoopbackHost(url.host ?? "") {
            return false
        }
        guard let origin = AgilValidation.origin(of: url) else {
            return false
        }
        return allowedOrigins.contains(origin)
    }

    static func encode(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }
}
