package com.agilcalls.sdk

import java.net.URI
import java.net.URLEncoder
import java.util.Locale

/**
 * Thrown when SDK configuration is invalid before anything is loaded.
 *
 * [message] never contains a token or any other user-supplied URL value, so it
 * is safe to show in a UI or send to analytics. [field] names the offending
 * option (for form validation).
 */
class AgilCallConfigException(
    val field: String,
    message: String,
) : IllegalArgumentException(message)

/**
 * The resolved `/embed.html` target.
 *
 * [url] contains the join token in its query string, per the embed contract.
 * **Never log it**; use [redactedUrl] instead. [toString] is already redacted.
 */
class AgilCallTarget internal constructor(
    val url: String,
    val origin: String,
    val serverUrl: String,
) {
    /** Same URL with `token`/`identity_token`/`id_token` masked. */
    val redactedUrl: String
        get() = AgilTokenRedactor.redactUrl(url)

    override fun toString(): String = "AgilCallTarget(origin=$origin, url=$redactedUrl)"
}

/**
 * Pure-JVM builder and validator for the hosted widget URL.
 *
 * Security invariants (covered by `AgilCallUrlTest`):
 *  - only `http:`/`https:` server URLs; plain HTTP is rejected outside
 *    loopback/dev hosts unless `allowInsecure` is deliberately set;
 *  - credentials, query strings and fragments are rejected in the server URL;
 *  - every value is length-limited and control-character checked;
 *  - the widget path cannot escape the configured server origin;
 *  - error messages never echo a token or URL value;
 *  - origin allowlist entries are exact, canonical origins (no wildcards).
 *
 * This file intentionally has no Android imports so it can run in plain JVM
 * unit tests.
 */
object AgilCallUrl {
    /** Page path resolved against the server base (root => `/embed.html`). */
    const val DEFAULT_WIDGET_PATH: String = "embed.html"

    /** Root-relative embed page path. */
    const val WIDGET_HTML_PATH: String = "/embed.html"

    const val MAX_URL_LENGTH: Int = 8192
    const val MAX_TOKEN_LENGTH: Int = 8192
    /** Server cap for `identityToken` (`joinRequestSchema`, OIDC verify). */
    const val MAX_IDENTITY_TOKEN_LENGTH: Int = 16_384
    const val MAX_ROOM_LENGTH: Int = 200
    const val MAX_NAME_LENGTH: Int = 120
    const val MAX_TENANT_LENGTH: Int = 64
    const val MAX_PATH_LENGTH: Int = 2048
    const val MAX_LANGUAGE_LENGTH: Int = 35
    const val MAX_ALLOWED_ORIGINS: Int = 16

    /** Locales the hosted widget actually understands (`lang=` / join `locale`). */
    val SUPPORTED_LANGUAGES: Set<String> = setOf("ru", "en")

    private val CONTROL_CHARS = Regex("[\\u0000-\\u001F\\u007F]")
    private val LANGUAGE_TAG = Regex("^[a-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$")
    private val ABSOLUTE_SCHEME = Regex("^[a-z][a-z0-9+.-]*:", RegexOption.IGNORE_CASE)
    private val IPV4_LOOPBACK = Regex("^127\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$")

    /** Percent-encoded `/`, `\` or NUL: rejected before the server can decode it. */
    private val ENCODED_SEPARATOR = Regex("%(?:2f|5c|00)", RegexOption.IGNORE_CASE)
    private val REDACTED_QUERY_KEYS = setOf(
        "token",
        "joinctoken",
        "join_token",
        "identity_token",
        "identitytoken",
        "id_token",
        "access_token",
        "refresh_token",
        "refreshtoken",
    )

    private class ServerParts(
        val normalized: String,
        val origin: String,
        val basePath: String,
    )

    /**
     * Validates and normalizes a server base URL.
     *
     * The result has no trailing slash, no query, no fragment, no credentials
     * and no explicit default port (`:443`/`:80`). A subpath is preserved:
     * `https://host/calls/` becomes `https://host/calls`.
     *
     * @throws AgilCallConfigException for an invalid or insecure URL.
     */
    @JvmStatic
    @JvmOverloads
    fun normalizeServerUrl(serverUrl: String, allowInsecure: Boolean = false): String =
        parseServer(serverUrl, allowInsecure).normalized

    /** Canonical `scheme://host[:port]` origin of a server URL. */
    @JvmStatic
    @JvmOverloads
    fun originOf(serverUrl: String, allowInsecure: Boolean = false): String =
        parseServer(serverUrl, allowInsecure).origin

    /** Canonical origin of an arbitrary http(s) URL, or `null` when unsafe. */
    @JvmStatic
    fun originOfUrl(url: String): String? {
        val raw = url.trim()
        if (raw.isEmpty() || raw.length > MAX_URL_LENGTH) return null
        if (CONTROL_CHARS.containsMatchIn(raw) || raw.contains('\\')) return null
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            return null
        }
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
        if (scheme != "https" && scheme != "http") return null
        if (uri.isOpaque || uri.rawAuthority.isNullOrEmpty()) return null
        if (uri.userInfo != null) return null
        val host = uri.host ?: return null
        val normalizedHost = normalizeHost(host)
        if (normalizedHost.isEmpty()) return null
        val port = uri.port
        if (port == 0 || port > 65535) return null
        return "$scheme://${authority(normalizedHost, port, scheme)}"
    }

    /**
     * Parses one exact allowlist origin.
     *
     * Rejects wildcards, paths, queries, fragments, credentials and non-http(s)
     * schemes. Plain HTTP is rejected outside dev hosts unless `allowInsecure`.
     */
    @JvmStatic
    @JvmOverloads
    fun parseOrigin(origin: String, allowInsecure: Boolean = false): String {
        val raw = origin.trim()
        if (raw.isEmpty()) fail("allowedOrigins", "origin must not be empty")
        if (raw.length > MAX_URL_LENGTH) fail("allowedOrigins", "origin is too long")
        if (raw.contains('*')) {
            fail("allowedOrigins", "wildcards are not allowed; list exact origins")
        }
        if (CONTROL_CHARS.containsMatchIn(raw) || raw.any { it.isWhitespace() }) {
            fail("allowedOrigins", "origin must not contain whitespace or control characters")
        }
        if (raw.contains('\\')) fail("allowedOrigins", "origin must use forward slashes")
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            fail("allowedOrigins", "origin must be an absolute http(s) URL")
        }
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
            ?: fail("allowedOrigins", "origin must be an absolute http(s) URL")
        if (scheme != "https" && scheme != "http") {
            fail("allowedOrigins", "origin must use http or https")
        }
        if (uri.isOpaque || uri.rawAuthority.isNullOrEmpty()) {
            fail("allowedOrigins", "origin must be an absolute http(s) URL")
        }
        if (uri.userInfo != null) fail("allowedOrigins", "origin must not include credentials")
        if (uri.rawQuery != null || uri.rawFragment != null) {
            fail("allowedOrigins", "origin must not include a query or fragment")
        }
        if (!uri.rawPath.isNullOrEmpty() && uri.rawPath != "/") {
            fail("allowedOrigins", "origin must not include a path")
        }
        val host = uri.host ?: fail("allowedOrigins", "origin is missing a host")
        val normalizedHost = normalizeHost(host)
        if (normalizedHost.isEmpty()) fail("allowedOrigins", "origin is missing a host")
        requireSecure(scheme, normalizedHost, allowInsecure, "allowedOrigins")
        val port = uri.port
        if (port == 0 || port > 65535) fail("allowedOrigins", "origin has an invalid port")
        return "$scheme://${authority(normalizedHost, port, scheme)}"
    }

    /**
     * Parses an exact-origin allowlist (max [MAX_ALLOWED_ORIGINS] entries).
     * Blank entries are rejected rather than silently ignored.
     */
    @JvmStatic
    @JvmOverloads
    fun parseAllowedOrigins(
        origins: Collection<String>,
        allowInsecure: Boolean = false,
    ): List<String> {
        val result = LinkedHashSet<String>()
        for (entry in origins) {
            if (result.size >= MAX_ALLOWED_ORIGINS) {
                fail("allowedOrigins", "too many origins (max $MAX_ALLOWED_ORIGINS)")
            }
            result.add(parseOrigin(entry, allowInsecure))
        }
        return result.toList()
    }

    /**
     * Resolves and validates the widget page path.
     *
     * Relative paths stay under a subpath deployment; a leading `/` addresses
     * the origin root. `..`, `.` (also percent-encoded, e.g. `%2e%2e`), encoded
     * slashes/backslashes, absolute URLs, backslashes, queries and fragments
     * are rejected, so the resolved page always stays inside the configured
     * deployment.
     */
    @JvmStatic
    @JvmOverloads
    fun resolveWidgetPath(serverBasePath: String, widgetPath: String = DEFAULT_WIDGET_PATH): String {
        val raw = widgetPath.trim()
        if (raw.isEmpty()) fail("widgetPath", "widgetPath must not be empty")
        if (raw.length > MAX_PATH_LENGTH) fail("widgetPath", "widgetPath is too long")
        if (CONTROL_CHARS.containsMatchIn(raw) || raw.any { it.isWhitespace() }) {
            fail("widgetPath", "widgetPath must not contain whitespace or control characters")
        }
        if (raw.contains('\\')) fail("widgetPath", "widgetPath must use forward slashes")
        if (raw.contains('?') || raw.contains('#')) {
            fail("widgetPath", "widgetPath must not contain a query or fragment")
        }
        if (raw.startsWith("//") || ABSOLUTE_SCHEME.containsMatchIn(raw)) {
            fail("widgetPath", "widgetPath must be a path, not an absolute URL")
        }
        // Validate the decoded form as well: `%2e%2e`, `%2f` and `%5c` would
        // otherwise be decoded by the server into a traversal/origin escape.
        if (ENCODED_SEPARATOR.containsMatchIn(raw)) {
            fail("widgetPath", "widgetPath must not contain percent-encoded separators")
        }
        val decoded = decodePercent(raw, "widgetPath")
        if (decoded.contains('\\') || CONTROL_CHARS.containsMatchIn(decoded) ||
            decoded.any { it.isWhitespace() }
        ) {
            fail("widgetPath", "widgetPath must use forward slashes")
        }
        if (decoded.contains('?') || decoded.contains('#')) {
            fail("widgetPath", "widgetPath must not contain a query or fragment")
        }
        if (decoded.contains("//")) fail("widgetPath", "widgetPath must not contain empty segments")
        for (segment in decoded.split('/')) {
            if (segment == "." || segment == "..") {
                fail("widgetPath", "widgetPath must not contain \".\" or \"..\" segments")
            }
        }
        val base = serverBasePath.trimEnd('/')
        val resolved = if (raw.startsWith('/')) raw else if (base.isEmpty()) "/$raw" else "$base/$raw"
        if (resolved == "/" || resolved.isEmpty()) {
            fail("widgetPath", "widgetPath must point to the embed page")
        }
        return resolved
    }

    /**
     * Builds the widget URL.
     *
     * `identityToken` is the OIDC/SSO assertion the widget forwards to the join
     * endpoint (`identity_token=`); `role` is the `host`/`moderator`/`guest` hint
     * used by the widget for local permissions and the signaling URL.
     *
     * @throws AgilCallConfigException for invalid configuration; messages never
     *         contain the rejected values (important for tokens).
     */
    @JvmStatic
    @JvmOverloads
    @Throws(AgilCallConfigException::class)
    fun build(
        serverUrl: String,
        room: String,
        token: String? = null,
        tenant: String? = "demo",
        participantName: String? = null,
        language: String? = null,
        theme: AgilTheme? = null,
        relayOnly: Boolean = false,
        widgetPath: String = DEFAULT_WIDGET_PATH,
        allowInsecure: Boolean = false,
        identityToken: String? = null,
        role: AgilRole? = null,
    ): AgilCallTarget {
        val server = parseServer(serverUrl, allowInsecure)
        val normalizedRoom = requireRoom(room)
        val normalizedToken = token?.let { requireToken(it, "token") }
        val normalizedIdentityToken = identityToken?.let {
            requireToken(it, "identityToken", MAX_IDENTITY_TOKEN_LENGTH)
        }
        val normalizedTenant = normalizeTenant(tenant)
        val normalizedName = normalizeName(participantName, "participantName", MAX_NAME_LENGTH)
        val normalizedLanguage = normalizeLanguage(language)
        val path = resolveWidgetPath(server.basePath, widgetPath)

        val params = ArrayList<Pair<String, String>>(10)
        params.add("server" to server.normalized)
        params.add("room" to normalizedRoom)
        if (normalizedToken != null) params.add("token" to normalizedToken)
        if (normalizedIdentityToken != null) {
            params.add("identity_token" to normalizedIdentityToken)
        }
        if (normalizedTenant != null) params.add("tenant" to normalizedTenant)
        if (role != null) params.add("role" to role.wire)
        if (normalizedLanguage != null) params.add("lang" to normalizedLanguage)
        if (normalizedName != null) params.add("name" to normalizedName)
        if (theme != null) params.add("theme" to theme.wire)
        if (relayOnly) params.add("relay" to "1")

        val query = params.joinToString("&") { (name, value) ->
            "${encodeQuery(name)}=${encodeQuery(value)}"
        }
        val url = "${server.origin}$path?$query"
        if (url.length > MAX_URL_LENGTH) fail("serverUrl", "the resulting URL is too long")
        return AgilCallTarget(url, server.origin, server.normalized)
    }

    /**
     * Navigation guard used by the WebView client.
     *
     * Only `about:blank`/`about:srcdoc`, the configured server origin and exact
     * allowlisted origins are permitted. `javascript:`, `file:`, `intent:`,
     * data URLs, credentials and other hosts are blocked.
     */
    @JvmStatic
    @JvmOverloads
    fun isAllowedNavigation(
        url: String,
        serverOrigin: String,
        allowedOrigins: Collection<String> = emptyList(),
    ): Boolean {
        val raw = url.trim()
        if (raw.isEmpty()) return false
        if (raw.equals("about:blank", ignoreCase = true) ||
            raw.equals("about:srcdoc", ignoreCase = true)
        ) {
            return true
        }
        if (CONTROL_CHARS.containsMatchIn(raw) || raw.contains('\\')) return false
        val origin = originOfUrl(raw) ?: return false
        if (origin == serverOrigin) return true
        for (allowed in allowedOrigins) {
            if (origin == allowed) return true
        }
        return false
    }

    /** Validates and trims a room id. */
    @JvmStatic
    fun requireRoom(room: String): String {
        val value = room.trim()
        if (value.isEmpty()) fail("room", "room is required")
        if (value.length > MAX_ROOM_LENGTH) fail("room", "room is too long (max $MAX_ROOM_LENGTH)")
        if (value == "." || value == ".." || value.contains('/') || value.contains('\\')) {
            fail("room", "room contains invalid path characters")
        }
        if (CONTROL_CHARS.containsMatchIn(value)) {
            fail("room", "room must not contain control characters")
        }
        return value
    }

    /** Validates a token; whitespace/control characters are rejected. */
    @JvmStatic
    @JvmOverloads
    fun requireToken(
        token: String,
        field: String = "token",
        maxLength: Int = MAX_TOKEN_LENGTH,
    ): String {
        val value = token.trim()
        if (value.isEmpty()) fail(field, "$field must not be empty")
        if (value.length > maxLength) fail(field, "$field is too long")
        if (CONTROL_CHARS.containsMatchIn(value) || value.any { it.isWhitespace() }) {
            fail(field, "$field must not contain whitespace or control characters")
        }
        return value
    }

    /** Trims an optional display name; blank becomes `null`. */
    @JvmStatic
    @JvmOverloads
    fun normalizeName(value: String?, field: String, maxLength: Int = MAX_NAME_LENGTH): String? {
        if (value == null) return null
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length > maxLength) fail(field, "$field is too long (max $maxLength)")
        if (CONTROL_CHARS.containsMatchIn(trimmed)) {
            fail(field, "$field must not contain control characters")
        }
        return trimmed
    }

    /** Normalizes the tenant (`demo` when blank/absent). */
    @JvmStatic
    fun normalizeTenant(tenant: String?): String? {
        if (tenant == null) return "demo"
        val trimmed = tenant.trim()
        if (trimmed.isEmpty()) return "demo"
        return normalizeName(trimmed, "tenant", MAX_TENANT_LENGTH)
    }

    /**
     * Validates and normalizes the widget locale.
     *
     * The hosted widget and the join endpoint only understand `ru` and `en`
     * (`joinRequestSchema.locale` is an enum), so regional tags such as
     * `en-US`/`ru-RU` are normalized to their primary subtag and any other
     * language is rejected instead of being silently ignored.
     */
    @JvmStatic
    fun normalizeLanguage(language: String?): String? {
        if (language == null) return null
        val value = language.trim()
        if (value.isEmpty()) return null
        // BCP-47 tags are case-insensitive (`RU-ru` == `ru-RU`).
        val normalized = value.lowercase(Locale.ROOT)
        if (normalized.length > MAX_LANGUAGE_LENGTH || !LANGUAGE_TAG.matches(normalized)) {
            fail("language", "language must be \"ru\" or \"en\"")
        }
        val primary = normalized.substringBefore('-')
        if (!SUPPORTED_LANGUAGES.contains(primary)) {
            fail("language", "language must be \"ru\" or \"en\" (unsupported locales are ignored)")
        }
        return primary
    }

    /** True when `token` appears as a value in a URL query key. */
    @JvmStatic
    fun isRedactedQueryKey(key: String): Boolean =
        REDACTED_QUERY_KEYS.contains(key.lowercase(Locale.ROOT))

    private fun parseServer(serverUrl: String, allowInsecure: Boolean): ServerParts {
        val raw = serverUrl.trim()
        if (raw.isEmpty()) fail("serverUrl", "serverUrl is required")
        if (raw.length > MAX_URL_LENGTH) fail("serverUrl", "serverUrl is too long")
        if (CONTROL_CHARS.containsMatchIn(raw)) {
            fail("serverUrl", "serverUrl must not contain control characters")
        }
        if (raw.contains('\\')) fail("serverUrl", "serverUrl must use forward slashes")
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            fail("serverUrl", "serverUrl must be an absolute http or https URL")
        }
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
            ?: fail("serverUrl", "serverUrl must be an absolute http or https URL")
        if (scheme != "https" && scheme != "http") {
            fail("serverUrl", "serverUrl must use http or https")
        }
        if (uri.isOpaque || uri.rawAuthority.isNullOrEmpty()) {
            fail("serverUrl", "serverUrl must be an absolute http or https URL")
        }
        if (uri.userInfo != null) {
            fail("serverUrl", "serverUrl must not contain credentials")
        }
        if (uri.rawQuery != null || uri.rawFragment != null) {
            fail("serverUrl", "serverUrl must not contain a query string or fragment")
        }
        val host = uri.host ?: fail("serverUrl", "serverUrl is missing a host")
        val normalizedHost = normalizeHost(host)
        if (normalizedHost.isEmpty()) fail("serverUrl", "serverUrl is missing a host")
        requireSecure(scheme, normalizedHost, allowInsecure, "serverUrl")
        val port = uri.port
        if (port == 0 || port > 65535) fail("serverUrl", "serverUrl has an invalid port")
        val path = (uri.rawPath ?: "").trimEnd('/')
        if (path.isNotEmpty()) {
            if (path.contains("//")) fail("serverUrl", "serverUrl path must not contain empty segments")
            for (segment in path.split('/')) {
                if (segment == "." || segment == "..") {
                    fail("serverUrl", "serverUrl path must not contain \".\" or \"..\" segments")
                }
            }
            // `%2e%2e`/`%2f` would be decoded by the server into a traversal.
            if (ENCODED_SEPARATOR.containsMatchIn(path)) {
                fail("serverUrl", "serverUrl path must not contain encoded separators")
            }
            val decodedPath = decodePercent(path, "serverUrl")
            for (segment in decodedPath.split('/')) {
                if (segment == "." || segment == "..") {
                    fail("serverUrl", "serverUrl path must not contain \".\" or \"..\" segments")
                }
            }
        }
        val normalized = "$scheme://${authority(normalizedHost, port, scheme)}$path"
        if (normalized.length > MAX_URL_LENGTH) fail("serverUrl", "serverUrl is too long")
        return ServerParts(
            normalized = normalized,
            origin = "$scheme://${authority(normalizedHost, port, scheme)}",
            basePath = path,
        )
    }

    private fun authority(host: String, port: Int, scheme: String): String {
        val hostPart = if (host.contains(':')) "[$host]" else host
        val defaultPort = if (scheme == "https") 443 else 80
        return if (port == -1 || port == defaultPort) hostPart else "$hostPart:$port"
    }

    private fun normalizeHost(host: String): String {
        var value = host.trim().lowercase(Locale.ROOT)
        if (value.startsWith("[")) value = value.substring(1)
        if (value.endsWith("]")) value = value.substring(0, value.length - 1)
        return value
    }

    private fun requireSecure(
        scheme: String,
        host: String,
        allowInsecure: Boolean,
        field: String,
    ) {
        if (scheme == "https") return
        if (allowInsecure || isDevHost(host)) return
        val label = if (field == "allowedOrigins") "origin" else "serverUrl"
        fail(
            field,
            "$label must use https (allowInsecure=true is only for local development)",
        )
    }

    private fun isDevHost(host: String): Boolean {
        val value = host.lowercase(Locale.ROOT)
        if (value == "localhost" ||
            value == "::1" ||
            value == "0:0:0:0:0:0:0:1" ||
            value == "10.0.2.2" ||
            value == "10.0.3.2"
        ) {
            return true
        }
        // Only a numeric IPv4 literal in 127.0.0.0/8 is loopback: a DNS name
        // such as `127.evil.com` or `127.0.0.1.nip.io` is attacker-controllable
        // and must not unlock plain HTTP.
        if (!IPV4_LOOPBACK.matches(value)) return false
        for (octet in value.split('.')) {
            val number = octet.toIntOrNull() ?: return false
            if (number !in 0..255) return false
        }
        return true
    }

    /**
     * Decodes `%XX` escapes so path validation sees what the server will see.
     * Invalid escapes are rejected; the caller only uses the result for checks.
     */
    private fun decodePercent(value: String, field: String): String {
        if (!value.contains('%')) return value
        val bytes = java.io.ByteArrayOutputStream(value.length)
        var index = 0
        while (index < value.length) {
            val character = value[index]
            if (character == '%') {
                if (index + 2 >= value.length) {
                    fail(field, "$field contains invalid percent-encoding")
                }
                val hex = value.substring(index + 1, index + 3)
                val byte = hex.toIntOrNull(16)
                    ?: fail(field, "$field contains invalid percent-encoding")
                bytes.write(byte)
                index += 3
            } else {
                val encoded = character.toString().toByteArray(Charsets.UTF_8)
                bytes.write(encoded, 0, encoded.size)
                index++
            }
        }
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }

    private fun encodeQuery(value: String): String = try {
        URLEncoder.encode(value, "UTF-8")
    } catch (_: Exception) {
        throw IllegalStateException("UTF-8 is not available")
    }

    private fun fail(field: String, message: String): Nothing =
        throw AgilCallConfigException(field, message)
}
