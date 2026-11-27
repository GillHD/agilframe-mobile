package com.agilcalls.sdk

/**
 * Theme scheme understood by the hosted widget (`theme=` / `agil:scheme`).
 * The full tenant theme still comes from the server; only the scheme is local.
 */
enum class AgilTheme(val wire: String) {
    LIGHT("light"),
    DARK("dark"),
    AUTO("auto"),
    ;

    companion object {
        /** Parses a wire value, or `null` for anything unsupported. */
        @JvmStatic
        fun fromWire(value: String?): AgilTheme? {
            if (value == null) return null
            val wire = value.trim().lowercase(java.util.Locale.ROOT)
            for (theme in values()) {
                if (theme.wire == wire) return theme
            }
            return null
        }
    }
}

/**
 * Role hint understood by the hosted widget (`role=`), matching
 * `docs/contract.md` §7 and the React Native/iOS SDKs.
 *
 * The server still derives the effective role from the verified token or
 * identity, so this is a UI/permissions hint, not an authorization grant.
 */
enum class AgilRole(val wire: String) {
    HOST("host"),
    MODERATOR("moderator"),
    GUEST("guest"),
    ;

    companion object {
        /** Parses a wire value, or `null` for anything unsupported. */
        @JvmStatic
        fun fromWire(value: String?): AgilRole? {
            if (value == null) return null
            val wire = value.trim().lowercase(java.util.Locale.ROOT)
            for (role in values()) {
                if (role.wire == wire) return role
            }
            return null
        }
    }
}

/**
 * Immutable configuration of one hosted call screen.
 *
 * Construction validates every field and throws [AgilCallConfigException] with
 * a token-free message. [token] and [identityToken] are deliberately omitted
 * from [toString].
 *
 * ```kotlin
 * val config = AgilCallConfig(
 *     serverUrl = "https://calls.example.com",
 *     room = "team-sync",
 *     token = joinToken,             // short-lived, never log it
 *     participantName = "Anna",
 *     theme = AgilTheme.AUTO,
 * )
 * ```
 */
data class AgilCallConfig(
    /** AgilFrame server, e.g. `https://calls.example.com` (subpath allowed). */
    val serverUrl: String,
    /** Room id. */
    val room: String,
    /** Short-lived join token; without it the widget shows its join screen. */
    val token: String? = null,
    /**
     * OIDC/SSO identity assertion (`identity_token=`), forwarded by the widget
     * to the join endpoint for tenants with `requireVerifiedIdentity`. Redacted
     * exactly like [token]; never log it.
     */
    val identityToken: String? = null,
    /** Tenant id; defaults to `demo`. */
    val tenant: String = "demo",
    /** Optional `host`/`moderator`/`guest` role hint (`role=`). */
    val role: AgilRole? = null,
    /** Display name used by the widget's join screen. */
    val participantName: String? = null,
    /** Widget locale (`lang`): `ru`/`en`; regional tags are normalized. */
    val language: String? = null,
    /** Theme scheme only (`theme`); the full theme comes from the server. */
    val theme: AgilTheme? = null,
    /** Forces TURN-only media (`relay=1`). */
    val relayOnly: Boolean = false,
    /**
     * Page path relative to [serverUrl]. Defaults to `embed.html`:
     * root server => `/embed.html`, `https://host/calls` => `/calls/embed.html`.
     * A leading `/` addresses the origin root.
     */
    val widgetPath: String = AgilCallUrl.DEFAULT_WIDGET_PATH,
    /**
     * Extra exact origins trusted by the navigation guard (SSO, external links
     * opened inside the widget). The widget origin is always trusted.
     */
    val allowedOrigins: List<String> = emptyList(),
    /** Pad the WebView for system bars/display cutout (edge-to-edge screens). */
    val safeArea: Boolean = true,
    /** Allows plain HTTP for non-dev hosts. Development only. */
    val allowInsecure: Boolean = false,
    /** Allows media to start without a user gesture (WebView autoplay). */
    val autoplay: Boolean = true,
    /** WebView background behind the transparent-ish widget shell. */
    val backgroundColor: Int = 0xFF080D16.toInt(),
    /** How long to wait for the widget handshake; `0` disables the watchdog. */
    val bridgeTimeoutMillis: Long = 20_000L,
    /**
     * Large-room participant cap for the bridge digest (2..200, default 200).
     * The WebView still receives `agil:state`; the SDK emits one bounded
     * snapshot plus deltas instead of the full id array on every tick.
     */
    val maxParticipants: Int = AgilLargeRoom.MAX_PARTICIPANTS,
) {
    init {
        AgilCallUrl.normalizeServerUrl(serverUrl, allowInsecure)
        AgilCallUrl.requireRoom(room)
        token?.let { AgilCallUrl.requireToken(it) }
        identityToken?.let {
            AgilCallUrl.requireToken(it, "identityToken", AgilCallUrl.MAX_IDENTITY_TOKEN_LENGTH)
        }
        AgilCallUrl.normalizeTenant(tenant)
        AgilCallUrl.normalizeName(participantName, "participantName", AgilCallUrl.MAX_NAME_LENGTH)
        AgilCallUrl.normalizeLanguage(language)
        AgilCallUrl.resolveWidgetPath(serverBasePath(), widgetPath)
        AgilCallUrl.parseAllowedOrigins(allowedOrigins, allowInsecure)
        if (bridgeTimeoutMillis < 0L) {
            throw AgilCallConfigException("bridgeTimeoutMillis", "bridgeTimeoutMillis must be >= 0")
        }
        if (maxParticipants < 2 || maxParticipants > AgilLargeRoom.MAX_PARTICIPANTS) {
            throw AgilCallConfigException(
                "maxParticipants",
                "maxParticipants must be between 2 and ${AgilLargeRoom.MAX_PARTICIPANTS}",
            )
        }
    }

    /** Canonical widget origin (`scheme://host[:port]`). */
    val serverOrigin: String
        get() = AgilCallUrl.originOf(serverUrl, allowInsecure)

    /** Canonical allowlist including the widget origin (duplicates removed). */
    val origins: List<String>
        get() {
            val result = LinkedHashSet<String>()
            result.add(serverOrigin)
            result.addAll(AgilCallUrl.parseAllowedOrigins(allowedOrigins, allowInsecure))
            return result.toList()
        }

    internal fun serverBasePath(): String {
        val normalized = AgilCallUrl.normalizeServerUrl(serverUrl, allowInsecure)
        val path = normalized.substringAfter("://").substringAfter('/', "")
        return if (path.isEmpty()) "" else "/$path"
    }

    /** Builds the resolved `/embed.html` target (contains the token). */
    fun toTarget(): AgilCallTarget = AgilCallUrl.build(
        serverUrl = serverUrl,
        room = room,
        token = token,
        tenant = tenant,
        participantName = participantName,
        language = language,
        theme = theme,
        relayOnly = relayOnly,
        widgetPath = widgetPath,
        allowInsecure = allowInsecure,
        identityToken = identityToken,
        role = role,
    )

    /** Token-free representation; safe for logs (though the SDK never logs). */
    override fun toString(): String = buildString {
        append("AgilCallConfig(serverUrl=").append(serverUrl)
        append(", room=").append(room)
        append(", token=").append(if (token == null) "null" else AgilTokenRedactor.REDACTED)
        append(", identityToken=")
            .append(if (identityToken == null) "null" else AgilTokenRedactor.REDACTED)
        append(", tenant=").append(tenant)
        append(", role=").append(role)
        append(", participantName=").append(participantName)
        append(", language=").append(language)
        append(", theme=").append(theme)
        append(", relayOnly=").append(relayOnly)
        append(", widgetPath=").append(widgetPath)
        append(", allowedOrigins=").append(allowedOrigins)
        append(", safeArea=").append(safeArea)
        append(", allowInsecure=").append(allowInsecure)
        append(", autoplay=").append(autoplay)
        append(", backgroundColor=").append(backgroundColor)
        append(", bridgeTimeoutMillis=").append(bridgeTimeoutMillis)
        append(", maxParticipants=").append(maxParticipants)
        append(')')
    }
}
