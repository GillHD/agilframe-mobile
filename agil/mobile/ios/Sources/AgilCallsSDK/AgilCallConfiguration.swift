import Foundation

/// Theme scheme understood by `/embed.html` (`?theme=` and `agil:scheme`).
public enum AgilThemeScheme: String, CaseIterable, Hashable, Sendable {
    case light
    case dark
    case auto
}

/// Everything the WebView needs to open a hosted AgilFrame room.
///
/// The initializer validates and normalizes every value. Invalid configuration
/// fails fast with ``AgilConfigurationError`` (field + reason only, never the
/// rejected value), so a typo in a token cannot leak into `localizedDescription`.
///
/// ```swift
/// let configuration = try AgilCallConfiguration(
///     serverURL: URL(string: "https://calls.example.com")!,
///     tenantId: "acme",
///     roomId: "support-42",
///     joinToken: join.joinToken,
///     participantName: "Alice",
///     theme: .dark,
///     language: "ru"
/// )
/// ```
public struct AgilCallConfiguration: Equatable, Sendable {
    /// Relative widget page resolved against ``serverURL``; `embed.html` keeps
    /// subpath deployments working (`https://host/calls` -> `/calls/embed.html`).
    public static let defaultWidgetPath = "embed.html"

    /// Normalized server base URL without a trailing slash.
    public let serverURL: URL
    /// Tenant id used by the widget (`tenant` query parameter).
    public let tenantId: String
    /// Room id used by the widget (`room` query parameter).
    public let roomId: String
    /// Short-lived join token (`token` query parameter). Never log it.
    public let joinToken: String?
    /// Display name for the widget's join screen (`name`).
    public let participantName: String?
    /// Initial theme scheme (`theme`).
    public let theme: AgilThemeScheme?
    /// Initial locale (`lang`). Accepts BCP-47 input but normalizes to the
    /// locales `/embed.html` actually understands: `ru` or `en`
    /// (`en-US` -> `en`); other languages are rejected.
    public let language: String?
    /// Forces TURN-only media through the widget (`relay=1`).
    public let relayOnly: Bool
    /// Extra exact origins trusted for **navigation**; the server origin is
    /// always trusted. They are not trusted for native bridge messages (only
    /// ``widgetOrigin`` is) and must use HTTPS unless they are loopback or
    /// ``allowsInsecureHTTP`` is `true`.
    public let allowedOrigins: [String]
    /// Widget page path relative to ``serverURL`` (default `embed.html`).
    public let widgetPath: String
    /// Corporate OIDC identity token. It is sent in the page URL as
    /// `identity_token`, because that is the `/embed.html` contract shared with
    /// the web/RN SDKs (see `docs/contract.md` §7); treat it as a short-lived
    /// secret and never log it.
    public let identityToken: String?
    /// Development escape hatch for non-loopback `http://` servers **and**
    /// allowlisted origins. Keep `false` in production.
    public let allowsInsecureHTTP: Bool
    /// Large-room participant cap for the bridge digest (2...200, default 200).
    /// The WebView still receives the widget's `agil:state`, but the SDK emits a
    /// single bounded snapshot plus deltas instead of the full id array on
    /// every tick (`AgilLargeRoom`).
    public let maxParticipants: Int
    /// Canonical `scheme://host[:port]` origin of the hosted widget.
    public let widgetOrigin: String

    /// Normalized server URL string used for the `server` query parameter.
    let normalizedServerURL: String

    public init(
        serverURL: URL,
        tenantId: String = "demo",
        roomId: String,
        joinToken: String? = nil,
        participantName: String? = nil,
        theme: AgilThemeScheme? = nil,
        language: String? = nil,
        relayOnly: Bool = false,
        allowedOrigins: [String] = [],
        widgetPath: String = AgilCallConfiguration.defaultWidgetPath,
        identityToken: String? = nil,
        allowsInsecureHTTP: Bool = false,
        maxParticipants: Int = AgilLargeRoom.maxParticipants
    ) throws {
        let server = try AgilValidation.serverURL(
            serverURL,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        let validatedRoomId = try AgilValidation.roomId(roomId)
        let validatedTenantId = try AgilValidation.tenantId(tenantId)
        let validatedName = try AgilValidation.participantName(participantName)
        let validatedLanguage = try AgilValidation.language(language)
        let validatedWidgetPath = try AgilValidation.widgetPath(widgetPath)
        let validatedOrigins = try AgilValidation.allowedOrigins(
            allowedOrigins,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        let validatedJoinToken = try AgilValidation.token(
            joinToken,
            field: .joinToken,
            maxLength: AgilValidation.maxJoinTokenLength
        )
        let validatedIdentityToken = try AgilValidation.token(
            identityToken,
            field: .identityToken,
            maxLength: AgilValidation.maxIdentityTokenLength
        )
        guard (2...AgilLargeRoom.maxParticipants).contains(maxParticipants) else {
            throw AgilConfigurationError(field: .maxParticipants, reason: .invalidValue, limit: AgilLargeRoom.maxParticipants)
        }

        self.serverURL = server.url
        self.normalizedServerURL = server.normalized
        self.widgetOrigin = server.origin
        self.tenantId = validatedTenantId
        self.roomId = validatedRoomId
        self.joinToken = validatedJoinToken
        self.participantName = validatedName
        self.theme = theme
        self.language = validatedLanguage
        self.relayOnly = relayOnly
        self.allowedOrigins = validatedOrigins
        self.widgetPath = validatedWidgetPath
        self.identityToken = validatedIdentityToken
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.maxParticipants = maxParticipants
    }

    /// String convenience. Equivalent to the `URL` initializer; malformed input
    /// throws ``AgilConfigurationError`` with a token-free message.
    public init(
        serverURL: String,
        tenantId: String = "demo",
        roomId: String,
        joinToken: String? = nil,
        participantName: String? = nil,
        theme: AgilThemeScheme? = nil,
        language: String? = nil,
        relayOnly: Bool = false,
        allowedOrigins: [String] = [],
        widgetPath: String = AgilCallConfiguration.defaultWidgetPath,
        identityToken: String? = nil,
        allowsInsecureHTTP: Bool = false,
        maxParticipants: Int = AgilLargeRoom.maxParticipants
    ) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !AgilValidation.hasControlCharacters(trimmed),
              let url = URL(string: trimmed) else {
            throw AgilConfigurationError(field: .serverURL, reason: .notAnAbsoluteURL)
        }
        try self.init(
            serverURL: url,
            tenantId: tenantId,
            roomId: roomId,
            joinToken: joinToken,
            participantName: participantName,
            theme: theme,
            language: language,
            relayOnly: relayOnly,
            allowedOrigins: allowedOrigins,
            widgetPath: widgetPath,
            identityToken: identityToken,
            allowsInsecureHTTP: allowsInsecureHTTP,
            maxParticipants: maxParticipants
        )
    }
}

// MARK: - Redacted descriptions

extension AgilCallConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    /// Safe to log: tokens are replaced with presence flags.
    public var description: String {
        return "AgilCallConfiguration(serverURL: \(AgilRedaction.redactURL(serverURL)), "
            + "tenantId: \(tenantId), roomId: \(roomId), "
            + "hasJoinToken: \(joinToken != nil), hasIdentityToken: \(identityToken != nil), "
            + "theme: \(theme?.rawValue ?? "none"), language: \(language ?? "none"), "
            + "relayOnly: \(relayOnly), widgetPath: \(widgetPath), "
            + "allowedOrigins: \(allowedOrigins.count), "
            + "allowsInsecureHTTP: \(allowsInsecureHTTP), "
            + "maxParticipants: \(maxParticipants))"
    }

    public var debugDescription: String {
        return description
    }
}
