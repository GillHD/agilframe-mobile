package com.agilcalls.sdk

import java.net.URI
import java.util.Locale

/**
 * Token redaction for URLs, error strings and arbitrary diagnostics.
 *
 * The SDK never logs. This helper exists so host applications can safely show
 * or send diagnostics without leaking a join token. It masks:
 *  - token-ish query parameters (`token`, `identity_token`, `id_token`, …);
 *  - JWT-looking strings anywhere in the text;
 *  - `Bearer …` header values.
 *
 * Redaction is best-effort: a random opaque secret without a `token=` key or a
 * JWT shape cannot be recognized. Never pass raw join URLs to logs regardless.
 */
object AgilTokenRedactor {
    const val REDACTED: String = "<redacted>"

    private val TOKEN_QUERY = Regex(
        "(?i)([?&](?:token|join_?token|identity_?token|id_token|access_token|refresh_?token)=)" +
            "[^&#\\s]+",
    )
    private val TOKEN_ASSIGNMENT = Regex(
        "(?i)\\b(token|join_?token|identity_?token|id_token|access_token|refresh_?token)" +
            "\\s*=\\s*[^&\\s#]+",
    )
    private val BEARER = Regex("(?i)(Bearer\\s+)[A-Za-z0-9._~+/=-]{8,}")
    private val JWT = Regex("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b")
    private val REDACTED_KEYS = setOf(
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

    /** Masks token query values and JWT/Bearer strings in free-form text. */
    @JvmStatic
    fun redactText(input: String?): String {
        if (input.isNullOrEmpty()) return ""
        var text = TOKEN_QUERY.replace(input) { match -> "${match.groupValues[1]}$REDACTED" }
        text = TOKEN_ASSIGNMENT.replace(text) { match -> "${match.groupValues[1]}=$REDACTED" }
        text = BEARER.replace(text) { match -> "${match.groupValues[1]}$REDACTED" }
        text = JWT.replace(text, REDACTED)
        return text
    }

    /**
     * Returns [url] with token query values masked, preserving other parameters
     * and the path. Falls back to [redactText] for malformed input.
     */
    @JvmStatic
    fun redactUrl(url: String?): String {
        val raw = url?.trim().orEmpty()
        if (raw.isEmpty()) return ""
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            return redactText(raw)
        }
        if (!uri.isAbsolute || uri.isOpaque) return redactText(raw)
        val authority = uri.rawAuthority ?: return redactText(raw)
        val hostPart = authority.substringAfter('@', authority)
        val query = uri.rawQuery
        val builder = StringBuilder()
        builder.append(uri.scheme).append("://").append(hostPart)
        builder.append(uri.rawPath ?: "")
        if (!query.isNullOrEmpty()) {
            builder.append('?')
            val pairs = query.split('&')
            for ((index, pair) in pairs.withIndex()) {
                if (index > 0) builder.append('&')
                val separator = pair.indexOf('=')
                val name = if (separator >= 0) pair.substring(0, separator) else pair
                if (REDACTED_KEYS.contains(name.lowercase(Locale.ROOT))) {
                    builder.append(name).append('=').append(REDACTED)
                } else {
                    builder.append(pair)
                }
            }
        }
        if (uri.rawFragment != null) builder.append('#').append(uri.rawFragment)
        return redactText(builder.toString())
    }

    /** Redacts an exception message and caps its length (never a stack trace). */
    @JvmStatic
    @JvmOverloads
    fun redactThrowable(error: Throwable?, maxLength: Int = 300): String {
        if (error == null) return "unknown error"
        val message = error.message
        val text = if (message.isNullOrBlank()) {
            error.javaClass.simpleName
        } else {
            "${error.javaClass.simpleName}: $message"
        }
        val redacted = redactText(text)
        return if (redacted.length > maxLength) redacted.substring(0, maxLength) else redacted
    }

    internal fun isRedactedKey(key: String): Boolean =
        REDACTED_KEYS.contains(key.lowercase(Locale.ROOT))
}
