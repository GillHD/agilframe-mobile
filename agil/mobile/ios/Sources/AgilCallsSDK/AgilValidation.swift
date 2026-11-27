import Foundation

/// Token-free configuration error thrown before any URL is built or request is
/// sent.
///
/// The error carries a field and a reason only: rejected values are never
/// embedded, so a mistyped token cannot leak into logs, analytics or crash
/// reports through `localizedDescription`.
public struct AgilConfigurationError: Error, Equatable, LocalizedError, Sendable {
    public enum Field: String, CaseIterable, Equatable, Sendable {
        case serverURL
        case tenantId
        case roomId
        case joinToken
        case participantName
        case theme
        case language
        case widgetPath
        case allowedOrigins
        case identityToken
        case apiKey
        case password
        case participantId
        case locale
        case maxParticipants
    }

    public enum Reason: String, Equatable, Sendable {
        case missing
        case tooLong
        case containsControlCharacters
        case containsWhitespace
        case invalidScheme
        case insecureHTTP
        case credentialsNotAllowed
        case queryOrFragmentNotAllowed
        case notAnAbsoluteURL
        case missingHost
        case wildcardOriginNotAllowed
        case originMustNotContainPath
        case invalidLanguageTag
        case tooManyOrigins
        case parentDirectorySegment
        case backslashNotAllowed
        case pathMustBeRelative
        case trailingSlashNotAllowed
        case escapeFromServerOrigin
        case invalidValue
    }

    public let field: Field
    public let reason: Reason
    /// Configured limit, when the reason is ``Reason/tooLong``.
    public let limit: Int?

    public init(field: Field, reason: Reason, limit: Int? = nil) {
        self.field = field
        self.reason = reason
        self.limit = limit
    }

    public var errorDescription: String? {
        return "\(field.rawValue) \(reasonDescription)"
    }

    private var reasonDescription: String {
        switch reason {
        case .missing:
            return "is required"
        case .tooLong:
            if let limit = limit {
                return "is too long (max \(limit) characters)"
            }
            return "is too long"
        case .containsControlCharacters:
            return "must not contain control characters"
        case .containsWhitespace:
            return "must not contain whitespace"
        case .invalidScheme:
            return "must use http or https"
        case .insecureHTTP:
            return "must use https (plain http is allowed only for loopback or with allowsInsecureHTTP)"
        case .credentialsNotAllowed:
            return "must not contain credentials"
        case .queryOrFragmentNotAllowed:
            return "must not contain a query string or fragment"
        case .notAnAbsoluteURL:
            return "must be an absolute URL"
        case .missingHost:
            return "is missing a host"
        case .wildcardOriginNotAllowed:
            return "must not contain wildcards; list exact origins"
        case .originMustNotContainPath:
            return "must be an origin without a path, query or fragment"
        case .invalidLanguageTag:
            return "must be a supported BCP-47 language tag (ru or en, optionally with a region such as en-US)"
        case .tooManyOrigins:
            return "supports at most 32 entries"
        case .parentDirectorySegment:
            return "must not contain \".\" or \"..\" segments"
        case .backslashNotAllowed:
            return "must use forward slashes"
        case .pathMustBeRelative:
            return "must be a relative path on the configured server"
        case .trailingSlashNotAllowed:
            return "must not end with a slash"
        case .escapeFromServerOrigin:
            return "must stay on the configured server origin"
        case .invalidValue:
            return "has an invalid value"
        }
    }
}

/// Internal validation + canonicalization shared by the configuration, URL
/// builder, view and REST client.
///
/// Every function is pure and unit-tested; none of them log or include rejected
/// values in errors.
enum AgilValidation {
    static let maxServerURLLength = 4_096
    static let maxRoomIdLength = 64
    static let maxTenantIdLength = 64
    static let maxParticipantNameLength = 120
    static let maxJoinTokenLength = 8_192
    static let maxIdentityTokenLength = 16_384
    static let maxWidgetPathLength = 512
    static let maxOriginLength = 2_048
    static let maxOrigins = 32
    static let maxAPIKeyLength = 512

    /// Server-side room ids: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`.
    static let roomIdPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
    static let tenantIdPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
    static let languagePattern = "^[a-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$"
    static let absoluteURLPattern = "^[A-Za-z][A-Za-z0-9+.-]*:"

    struct Server {
        let url: URL
        let normalized: String
        let origin: String
    }

    // MARK: - Character checks

    static func hasControlCharacters(_ value: String) -> Bool {
        return value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    static func containsWhitespace(_ value: String) -> Bool {
        return value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        var value = host.lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value == "localhost" || value == "127.0.0.1" || value == "::1"
    }

    // MARK: - Origins

    /// Canonical `scheme://host[:port]` with lowercased host and default ports
    /// removed. Returns `nil` for non-http(s), missing hosts or IPv6-invalid
    /// input.
    static func canonicalOrigin(scheme: String, host: String, port: Int?) -> String? {
        let scheme = scheme.lowercased()
        guard scheme == "https" || scheme == "http" else {
            return nil
        }
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else {
            return nil
        }
        if normalizedHost.hasPrefix("[") && normalizedHost.hasSuffix("]") {
            normalizedHost = String(normalizedHost.dropFirst().dropLast())
        }
        let authorityHost = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        let effectivePort = port ?? (scheme == "https" ? 443 : 80)
        var origin = "\(scheme)://\(authorityHost)"
        if !(scheme == "https" && effectivePort == 443) && !(scheme == "http" && effectivePort == 80) {
            origin += ":\(effectivePort)"
        }
        return origin
    }

    /// Exact origin of an absolute http(s) URL; `nil` for anything else,
    /// including URLs with credentials.
    static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        if components.user != nil || components.password != nil {
            return nil
        }
        return canonicalOrigin(scheme: scheme, host: host, port: components.port)
    }

    // MARK: - Server URL

    static func serverURL(_ url: URL, allowsInsecureHTTP: Bool) throws -> Server {
        guard url.absoluteString.count <= maxServerURLLength else {
            throw AgilConfigurationError(field: .serverURL, reason: .tooLong, limit: maxServerURLLength)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            throw AgilConfigurationError(field: .serverURL, reason: .notAnAbsoluteURL)
        }
        guard scheme == "https" || scheme == "http" else {
            throw AgilConfigurationError(field: .serverURL, reason: .invalidScheme)
        }
        if components.user != nil || components.password != nil {
            throw AgilConfigurationError(field: .serverURL, reason: .credentialsNotAllowed)
        }
        if components.query != nil || components.fragment != nil {
            throw AgilConfigurationError(field: .serverURL, reason: .queryOrFragmentNotAllowed)
        }
        if scheme == "http" && !allowsInsecureHTTP && !isLoopbackHost(host) {
            throw AgilConfigurationError(field: .serverURL, reason: .insecureHTTP)
        }
        // Reject encoded dot segments too: `%2e%2e` may be decoded by a proxy or
        // by the server's static handler. Android applies the same rule.
        let decodedPath = components.percentEncodedPath.removingPercentEncoding
            ?? components.percentEncodedPath
        let pathSegments = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
        if pathSegments.contains(".") || pathSegments.contains("..") {
            throw AgilConfigurationError(field: .serverURL, reason: .parentDirectorySegment)
        }

        var normalizedComponents = components
        normalizedComponents.scheme = scheme
        normalizedComponents.host = host.lowercased()
        normalizedComponents.query = nil
        normalizedComponents.fragment = nil
        normalizedComponents.user = nil
        normalizedComponents.password = nil
        let defaultPort = scheme == "https" ? 443 : 80
        if normalizedComponents.port == defaultPort {
            normalizedComponents.port = nil
        }
        normalizedComponents.percentEncodedPath = stripTrailingSlashes(components.percentEncodedPath)
        guard let normalizedURL = normalizedComponents.url else {
            throw AgilConfigurationError(field: .serverURL, reason: .invalidValue)
        }
        // URLComponents may serialize a root URL as "https://host/"; the
        // public contract is a base URL without a trailing slash.
        var normalized = normalizedURL.absoluteString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard let canonicalURL = URL(string: normalized),
              let origin = origin(of: canonicalURL) else {
            throw AgilConfigurationError(field: .serverURL, reason: .invalidValue)
        }
        return Server(url: canonicalURL, normalized: normalized, origin: origin)
    }

    private static func stripTrailingSlashes(_ path: String) -> String {
        var value = path
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    // MARK: - Identifiers and text

    static func roomId(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AgilConfigurationError(field: .roomId, reason: .missing)
        }
        if hasControlCharacters(trimmed) {
            throw AgilConfigurationError(field: .roomId, reason: .containsControlCharacters)
        }
        if trimmed.count > maxRoomIdLength {
            throw AgilConfigurationError(field: .roomId, reason: .tooLong, limit: maxRoomIdLength)
        }
        guard matches(trimmed, roomIdPattern) else {
            throw AgilConfigurationError(field: .roomId, reason: .invalidValue)
        }
        return trimmed
    }

    static func tenantId(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AgilConfigurationError(field: .tenantId, reason: .missing)
        }
        if hasControlCharacters(trimmed) {
            throw AgilConfigurationError(field: .tenantId, reason: .containsControlCharacters)
        }
        if trimmed.count > maxTenantIdLength {
            throw AgilConfigurationError(field: .tenantId, reason: .tooLong, limit: maxTenantIdLength)
        }
        guard matches(trimmed, tenantIdPattern) else {
            throw AgilConfigurationError(field: .tenantId, reason: .invalidValue)
        }
        return trimmed
    }

    static func participantName(_ value: String?) throws -> String? {
        guard let value = value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if hasControlCharacters(trimmed) {
            throw AgilConfigurationError(field: .participantName, reason: .containsControlCharacters)
        }
        if trimmed.count > maxParticipantNameLength {
            throw AgilConfigurationError(
                field: .participantName,
                reason: .tooLong,
                limit: maxParticipantNameLength
            )
        }
        return trimmed
    }

    static func token(
        _ value: String?,
        field: AgilConfigurationError.Field,
        maxLength: Int
    ) throws -> String? {
        guard let value = value else {
            return nil
        }
        if value.isEmpty {
            throw AgilConfigurationError(field: field, reason: .missing)
        }
        if value.count > maxLength {
            throw AgilConfigurationError(field: field, reason: .tooLong, limit: maxLength)
        }
        if hasControlCharacters(value) {
            throw AgilConfigurationError(field: field, reason: .containsControlCharacters)
        }
        if containsWhitespace(value) {
            throw AgilConfigurationError(field: field, reason: .containsWhitespace)
        }
        return value
    }

    /// Accepts a BCP-47 tag but normalizes it to the only locales `/embed.html`
    /// understands (`ru`/`en`). A region/script subtag is allowed
    /// (`en-US` -> `en`); unsupported languages are rejected instead of being
    /// silently ignored by the widget.
    static func language(_ value: String?) throws -> String? {
        guard let value = value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if hasControlCharacters(trimmed) {
            throw AgilConfigurationError(field: .language, reason: .containsControlCharacters)
        }
        let normalized = trimmed.lowercased()
        guard normalized.count <= 35, matches(normalized, languagePattern) else {
            throw AgilConfigurationError(field: .language, reason: .invalidLanguageTag)
        }
        let primary = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalized
        guard primary == "ru" || primary == "en" else {
            throw AgilConfigurationError(field: .language, reason: .invalidLanguageTag)
        }
        return primary
    }

    static func apiKey(_ value: String?) throws -> String? {
        guard let value = value else {
            return nil
        }
        if value.isEmpty {
            throw AgilConfigurationError(field: .apiKey, reason: .missing)
        }
        if value.count > maxAPIKeyLength {
            throw AgilConfigurationError(field: .apiKey, reason: .tooLong, limit: maxAPIKeyLength)
        }
        if hasControlCharacters(value) {
            throw AgilConfigurationError(field: .apiKey, reason: .containsControlCharacters)
        }
        if containsWhitespace(value) {
            throw AgilConfigurationError(field: .apiKey, reason: .containsWhitespace)
        }
        return value
    }

    static func participantId(_ value: String?) throws -> String? {
        guard let value = value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AgilConfigurationError(field: .participantId, reason: .missing)
        }
        if trimmed.count > maxRoomIdLength {
            throw AgilConfigurationError(
                field: .participantId,
                reason: .tooLong,
                limit: maxRoomIdLength
            )
        }
        if hasControlCharacters(trimmed) {
            throw AgilConfigurationError(
                field: .participantId,
                reason: .containsControlCharacters
            )
        }
        return trimmed
    }

    static func password(_ value: String?) throws -> String? {
        guard let value = value else {
            return nil
        }
        if value.isEmpty {
            throw AgilConfigurationError(field: .password, reason: .missing)
        }
        if value.count > 200 {
            throw AgilConfigurationError(field: .password, reason: .tooLong, limit: 200)
        }
        if hasControlCharacters(value) {
            throw AgilConfigurationError(
                field: .password,
                reason: .containsControlCharacters
            )
        }
        return value
    }

    static func locale(_ value: String?) throws -> String? {
        guard let value = value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "ru" || trimmed == "en" else {
            throw AgilConfigurationError(field: .locale, reason: .invalidValue)
        }
        return trimmed
    }

    // MARK: - Widget path and origins

    static func widgetPath(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AgilConfigurationError(field: .widgetPath, reason: .missing)
        }
        if trimmed.count > maxWidgetPathLength {
            throw AgilConfigurationError(
                field: .widgetPath,
                reason: .tooLong,
                limit: maxWidgetPathLength
            )
        }
        if hasControlCharacters(trimmed) {
            throw AgilConfigurationError(
                field: .widgetPath,
                reason: .containsControlCharacters
            )
        }
        if containsWhitespace(trimmed) {
            throw AgilConfigurationError(field: .widgetPath, reason: .containsWhitespace)
        }
        if trimmed.contains("\\") {
            throw AgilConfigurationError(field: .widgetPath, reason: .backslashNotAllowed)
        }
        if trimmed.contains("?") || trimmed.contains("#") {
            throw AgilConfigurationError(
                field: .widgetPath,
                reason: .queryOrFragmentNotAllowed
            )
        }
        if trimmed.hasPrefix("//") || matches(trimmed, absoluteURLPattern) {
            throw AgilConfigurationError(field: .widgetPath, reason: .pathMustBeRelative)
        }
        if trimmed.allSatisfy({ $0 == "/" }) {
            throw AgilConfigurationError(field: .widgetPath, reason: .invalidValue)
        }
        if trimmed.hasSuffix("/") {
            throw AgilConfigurationError(
                field: .widgetPath,
                reason: .trailingSlashNotAllowed
            )
        }
        // Reject encoded dot segments as well: `%2e%2e` is decoded by the server.
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(".") || segments.contains("..") {
            throw AgilConfigurationError(
                field: .widgetPath,
                reason: .parentDirectorySegment
            )
        }
        return trimmed
    }

    /// Validates exact-origin entries and canonicalizes them. Plain HTTP is
    /// rejected for non-loopback hosts unless `allowsInsecureHTTP` is set, so an
    /// allowlisted SSO origin cannot silently downgrade navigation.
    static func allowedOrigins(
        _ values: [String],
        allowsInsecureHTTP: Bool = false
    ) throws -> [String] {
        guard values.count <= maxOrigins else {
            throw AgilConfigurationError(
                field: .allowedOrigins,
                reason: .tooManyOrigins
            )
        }
        var seen: Set<String> = []
        var result: [String] = []
        for rawValue in values {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw AgilConfigurationError(field: .allowedOrigins, reason: .missing)
            }
            if trimmed.count > maxOriginLength {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .tooLong,
                    limit: maxOriginLength
                )
            }
            if trimmed.contains("*") {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .wildcardOriginNotAllowed
                )
            }
            if hasControlCharacters(trimmed) {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .containsControlCharacters
                )
            }
            if containsWhitespace(trimmed) {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .containsWhitespace
                )
            }
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased() else {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .notAnAbsoluteURL
                )
            }
            guard scheme == "https" || scheme == "http" else {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .invalidScheme
                )
            }
            guard let host = components.host, !host.isEmpty else {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .missingHost
                )
            }
            // Plain HTTP in the allowlist would silently downgrade main-frame
            // navigation. Match Android: only loopback development hosts are
            // allowed without the explicit `allowsInsecureHTTP` flag.
            if scheme == "http" && !allowsInsecureHTTP && !isLoopbackHost(host) {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .insecureHTTP
                )
            }
            if components.user != nil || components.password != nil {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .credentialsNotAllowed
                )
            }
            if components.query != nil || components.fragment != nil {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .queryOrFragmentNotAllowed
                )
            }
            let path = components.percentEncodedPath
            if !(path.isEmpty || path == "/") {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .originMustNotContainPath
                )
            }
            guard let origin = canonicalOrigin(
                scheme: scheme,
                host: host,
                port: components.port
            ) else {
                throw AgilConfigurationError(
                    field: .allowedOrigins,
                    reason: .invalidValue
                )
            }
            if seen.insert(origin).inserted {
                result.append(origin)
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
