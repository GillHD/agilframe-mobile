package com.agilcalls.sdk

/**
 * Body of `POST /v1/rooms/{room}/join`.
 *
 * [password], [inviteToken] and [identityToken] are secrets: they are omitted
 * from [toString] and never included in errors.
 */
data class AgilJoinRequest(
    /** Display name used by the widget join screen. */
    val name: String? = null,
    /** Room password, when the room is password-protected. */
    val password: String? = null,
    /** Stable participant id for reconnects. */
    val participantId: String? = null,
    /**
     * Locale hint; normalized to `ru`/`en` (the server accepts only those two
     * values and the widget ignores anything else).
     */
    val locale: String? = null,
    /**
     * Optional invite token sent as `Authorization: Bearer …`. Use it instead
     * of a password for invite links; it is never logged.
     */
    val inviteToken: String? = null,
    /**
     * OIDC/SSO identity assertion (`identityToken` in the join body). Required
     * by tenants with `security.requireVerifiedIdentity`; otherwise the server
     * answers `401 identity_required`. Never logged.
     */
    val identityToken: String? = null,
) {
    init {
        AgilCallUrl.normalizeName(name, "name", AgilCallUrl.MAX_NAME_LENGTH)
        AgilCallUrl.normalizeName(participantId, "participantId", 128)
        AgilCallUrl.normalizeLanguage(locale)
        if (password != null) {
            if (password.length > MAX_PASSWORD_LENGTH || containsControl(password)) {
                throw AgilCallConfigException("password", "password is invalid")
            }
        }
        if (inviteToken != null) {
            AgilCallUrl.requireToken(inviteToken, "inviteToken")
        }
        if (identityToken != null) {
            AgilCallUrl.requireToken(
                identityToken,
                "identityToken",
                AgilCallUrl.MAX_IDENTITY_TOKEN_LENGTH,
            )
        }
    }

    /** Token-free representation; safe for logs (the SDK never logs). */
    override fun toString(): String = "AgilJoinRequest(name=$name, " +
        "password=${if (password == null) "null" else AgilTokenRedactor.REDACTED}, " +
        "participantId=$participantId, locale=$locale, " +
        "inviteToken=${if (inviteToken == null) "null" else AgilTokenRedactor.REDACTED}, " +
        "identityToken=${if (identityToken == null) "null" else AgilTokenRedactor.REDACTED})"

    private fun containsControl(value: String): Boolean =
        value.any { it.code < 0x20 || it.code == 0x7F }

    companion object {
        const val MAX_PASSWORD_LENGTH: Int = 256
    }
}

/** Room data returned by the join endpoint. */
data class AgilRoom(
    val id: String,
    val tenantId: String? = null,
    val name: String? = null,
    val locked: Boolean = false,
)

/** Participant data returned by the join endpoint. */
data class AgilParticipant(
    val id: String,
    val name: String? = null,
    val role: String? = null,
)

/**
 * Typed `POST /v1/rooms/{room}/join` outcome.
 *
 * The join endpoint has two successful shapes:
 *  - **200** with a short-lived [Joined.token];
 *  - **202** `{pending:true, requestId, roomId, status:'pending', expiresAt,
 *    pollAfterMs}` when the tenant enables `security.waitingRoom` — no token,
 *    the host must poll `GET /v1/rooms/{room}/lobby/{requestId}` (or let the
 *    widget's own lobby screen handle it).
 *
 * Pattern-match instead of assuming a token:
 *
 * ```kotlin
 * when (val result = ...) {
 *     is AgilJoinResult.Joined -> loadCall(result.token)
 *     is AgilJoinResult.Pending -> showLobby(result.requestId, result.pollAfterMillis)
 * }
 * ```
 */
sealed class AgilJoinResult {
    /** Wire status: [STATUS_JOINED] or [STATUS_PENDING]. */
    abstract val status: String

    /** True for [Joined]. */
    val isJoined: Boolean
        get() = this is Joined

    /** True for [Pending] (waiting-room ticket, no token yet). */
    val isPending: Boolean
        get() = this is Pending

    /**
     * Join token for [Joined], `null` for [Pending]. Never log it; hand it to
     * [AgilCallConfig.token].
     */
    open val token: String?
        get() = null

    /** Epoch millis at which the token/ticket expires (`0` when unknown). */
    abstract val expiresAtEpochMillis: Long

    /** Successful join: token, room/participant and effective permissions. */
    data class Joined(
        override val token: String,
        override val expiresAtEpochMillis: Long = 0L,
        val room: AgilRoom? = null,
        val participant: AgilParticipant? = null,
        val permissions: List<String> = emptyList(),
    ) : AgilJoinResult() {
        init {
            require(token.isNotBlank()) { "token must not be blank" }
            require(token.length <= AgilCallUrl.MAX_TOKEN_LENGTH) { "token is too long" }
        }

        override val status: String
            get() = STATUS_JOINED

        /** Token-free representation; safe for logs (the SDK never logs). */
        override fun toString(): String = "AgilJoinResult.Joined(token=" +
            "${AgilTokenRedactor.REDACTED}, expiresAtEpochMillis=$expiresAtEpochMillis, " +
            "room=$room, participant=$participant, permissions=$permissions)"
    }

    /**
     * Waiting-room ticket (HTTP 202 or `pending:true`); the server issued no
     * join token yet.
     */
    data class Pending(
        val requestId: String,
        override val status: String = STATUS_PENDING,
        val roomId: String? = null,
        override val expiresAtEpochMillis: Long = 0L,
        /** Server-recommended lobby poll interval in millis (`0` when absent). */
        val pollAfterMillis: Long = 0L,
    ) : AgilJoinResult() {
        init {
            require(requestId.isNotBlank()) { "requestId must not be blank" }
            require(requestId.length <= AgilCallUrl.MAX_NAME_LENGTH) { "requestId is too long" }
        }

        /** Ticket-free representation; safe for logs (the SDK never logs). */
        override fun toString(): String = "AgilJoinResult.Pending(requestId=$requestId, " +
            "status=$status, roomId=$roomId, expiresAtEpochMillis=$expiresAtEpochMillis, " +
            "pollAfterMillis=$pollAfterMillis)"
    }

    companion object {
        /** Wire value of a successful join. */
        const val STATUS_JOINED: String = "joined"

        /** Wire value of a waiting-room ticket. */
        const val STATUS_PENDING: String = "pending"
    }
}

/**
 * Typed join failures. Each case has a stable type and a token-free [message];
 * [Http] additionally exposes the server error code and redacted message.
 */
sealed class AgilJoinException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    /** Invalid client configuration or join request; no request was sent. */
    class InvalidConfig(
        val field: String?,
        message: String,
    ) : AgilJoinException(message)

    /** DNS/TLS/connection failure or an interrupted response. */
    class Network(
        message: String,
        cause: Throwable? = null,
    ) : AgilJoinException(message, cause)

    /** Connect/read timeout. */
    class Timeout(
        message: String,
        cause: Throwable? = null,
    ) : AgilJoinException(message, cause)

    /** Non-2xx response; redirects are treated as errors on purpose. */
    class Http(
        val status: Int,
        val code: String? = null,
        serverMessage: String? = null,
    ) : AgilJoinException(
        buildString {
            append("join failed with HTTP ").append(status)
            if (!code.isNullOrBlank()) append(" (").append(code).append(')')
        },
    ) {
        /** Redacted and truncated server message, when the server sent one. */
        val serverMessage: String? = serverMessage?.let {
            val redacted = AgilTokenRedactor.redactText(it)
            if (redacted.length > 300) redacted.substring(0, 300) else redacted
        }
    }

    /** The response is not the documented JSON shape. */
    class Parse(
        message: String = "the join response is malformed",
    ) : AgilJoinException(message)

    /** The request was cancelled by the caller. */
    class Cancelled : AgilJoinException("join request was cancelled")

    /** [AgilClient.close] was called. */
    class Closed : AgilJoinException("AgilClient is closed")
}
