import Foundation

/// Token redaction helpers used by every error/description the SDK produces.
///
/// The SDK itself never logs. These helpers exist so host apps can safely log
/// diagnostics without leaking join tokens, identity tokens or JWTs, and they
/// are applied automatically to `localizedDescription` of SDK errors.
public enum AgilRedaction {
    private static let sensitiveQueryKeys: Set<String> = [
        "token",
        "join_token",
        "joinctoken",
        "jointoken",
        "identity_token",
        "identitytoken",
        "id_token",
        "idtoken",
        "access_token",
        "accesstoken",
        "password",
        "api_key",
        "apikey"
    ]

    // (?i) query parameter values: token=..., identity_token=..., camelCase
    // (`joinToken`) and percent-encoded assignment (`token%3D...`). Optional
    // whitespace around `=` covers formatted host logs.
    private static let tokenQueryPattern =
        #"(?i)(^|[?&\s])((?:token|join_?token|jointoken|identity_?token|identitytoken|id_?token|idtoken|access_?token|accesstoken|password|api_?key|apikey)\s*(?:=|%3d)\s*)[^&\s#]+"#
    private static let jwtPattern =
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#
    private static let bearerPattern =
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#
    private static let urlCredentialsPattern =
        #"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@"#

    /// Masks query-token values, JWTs, `Bearer` credentials and URL userinfo in
    /// free-form text. Idempotent and safe for any input.
    public static func redactTokenText(_ text: String) -> String {
        var result = text
        result = replace(urlCredentialsPattern, in: result, with: "$1redacted@")
        result = replace(tokenQueryPattern, in: result, with: "$1$2redacted")
        result = replace(jwtPattern, in: result, with: "redacted")
        result = replace(bearerPattern, in: result, with: "Bearer redacted")
        return result
    }

    /// URL safe for logs: credentials and sensitive query values are masked,
    /// other parameters are kept (useful for diagnosing `room`/`server`).
    public static func redactURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redactTokenText(url.absoluteString)
        }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                if sensitiveQueryKeys.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "redacted")
                }
                return URLQueryItem(name: item.name, value: redactTokenText(item.value ?? ""))
            }
        }
        let rendered = components.string ?? url.absoluteString
        return redactTokenText(rendered)
    }

    private static func replace(
        _ pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
