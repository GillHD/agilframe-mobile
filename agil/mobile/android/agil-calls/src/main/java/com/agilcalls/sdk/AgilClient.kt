package com.agilcalls.sdk

import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException

/**
 * Configuration of [AgilClient].
 *
 * `serverUrl` is validated with the same rules as [AgilCallConfig]: HTTPS is
 * required outside loopback/dev hosts unless [allowInsecure] is set.
 */
data class AgilClientConfig(
    val serverUrl: String,
    val allowInsecure: Boolean = false,
    val connectTimeoutMillis: Int = 15_000,
    val readTimeoutMillis: Int = 20_000,
    /** Sent as `User-Agent`; never contains secrets. */
    val userAgent: String = DEFAULT_USER_AGENT,
) {
    init {
        if (connectTimeoutMillis !in 1..120_000) {
            throw AgilCallConfigException(
                "connectTimeoutMillis",
                "connectTimeoutMillis must be between 1 and 120000",
            )
        }
        if (readTimeoutMillis !in 1..120_000) {
            throw AgilCallConfigException(
                "readTimeoutMillis",
                "readTimeoutMillis must be between 1 and 120000",
            )
        }
        if (userAgent.isBlank() || userAgent.length > 200 ||
            userAgent.any { it.code !in 0x20..0x7E }
        ) {
            throw AgilCallConfigException("userAgent", "userAgent is invalid")
        }
        AgilCallUrl.normalizeServerUrl(serverUrl, allowInsecure)
    }

    /** Canonical server origin. */
    val serverOrigin: String
        get() = AgilCallUrl.originOf(serverUrl, allowInsecure)

    override fun toString(): String = "AgilClientConfig(serverUrl=$serverUrl, " +
        "allowInsecure=$allowInsecure, connectTimeoutMillis=$connectTimeoutMillis, " +
        "readTimeoutMillis=$readTimeoutMillis, userAgent=$userAgent)"

    companion object {
        const val DEFAULT_USER_AGENT: String = "agil-calls-android/0.1.0"
    }
}

/** Receives the result of [AgilClient.join] on the callback executor. */
interface AgilJoinCallback {
    /**
     * Called for both successful shapes: [AgilJoinResult.Joined] (token ready)
     * and [AgilJoinResult.Pending] (waiting-room ticket, no token yet).
     */
    fun onJoined(result: AgilJoinResult)

    fun onError(error: AgilJoinException)
}

/** Cancellation handle returned by [AgilClient.join]. */
class AgilJoinHandle internal constructor(
    private val future: Future<*>?,
) : Closeable {
    /** Requests cancellation; the callback may still receive [AgilJoinException.Cancelled]. */
    fun cancel() {
        future?.cancel(true)
    }

    val isCancelled: Boolean
        get() = future?.isCancelled == true

    override fun close() = cancel()
}

/**
 * Small join API for `POST /v1/rooms/{room}/join` built on
 * [HttpURLConnection] and a private executor — no Retrofit/OkHttp/coroutines.
 *
 * ```kotlin
 * val client = AgilClient(AgilClientConfig("https://calls.example.com"))
 * client.join("team-sync", AgilJoinRequest(name = "Anna"), object : AgilJoinCallback {
 *     override fun onJoined(result: AgilJoinResult) {
 *         when (result) {
 *             is AgilJoinResult.Joined ->
 *                 // result.token — hand it to AgilCallConfig, never log it
 *                 callView.load(AgilCallConfig("https://calls.example.com", "team-sync", result.token))
 *             is AgilJoinResult.Pending ->
 *                 // waiting room: poll /v1/rooms/{room}/lobby/{requestId}
 *                 showLobby(result.requestId, result.pollAfterMillis)
 *         }
 *     }
 *     override fun onError(error: AgilJoinException) { showError(error.message) }
 * })
 * ```
 *
 * The client holds no API key: never embed an admin key in a mobile app. Room
 * creation and admin calls must stay on the customer's backend.
 */
class AgilClient @JvmOverloads constructor(
    private val config: AgilClientConfig,
    executor: ExecutorService? = null,
    callbackExecutor: Executor? = null,
) : Closeable {
    private val ownsExecutor: Boolean = executor == null
    private val worker: ExecutorService = executor ?: Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "agil-calls-join").apply { isDaemon = true }
    }
    private val callbacks: Executor = callbackExecutor ?: MainThreadExecutor()
    private val serverUrl: String = AgilCallUrl.normalizeServerUrl(config.serverUrl, config.allowInsecure)

    @Volatile
    private var closed: Boolean = false

    /** True after [close]. */
    val isClosed: Boolean
        get() = closed

    /** Starts a join request with an empty [AgilJoinRequest]. */
    fun join(roomId: String, callback: AgilJoinCallback): AgilJoinHandle =
        join(roomId, AgilJoinRequest(), callback)

    /** Starts a join request; the callback always runs asynchronously. */
    fun join(
        roomId: String,
        request: AgilJoinRequest,
        callback: AgilJoinCallback,
    ): AgilJoinHandle {
        val room = validatedRoom(roomId, callback) ?: return AgilJoinHandle(null)
        if (closed) {
            // A closed client still settles the callback (the typed `Closed`
            // error), otherwise a host racing screen teardown waits forever.
            deliverError(callback, AgilJoinException.Closed(), deliverEvenIfClosed = true)
            return AgilJoinHandle(null)
        }
        val future = try {
            worker.submit {
                val result = try {
                    executeOrThrow(room, request)
                } catch (error: AgilJoinException) {
                    deliverError(callback, error)
                    return@submit
                } catch (error: Exception) {
                    // Never let a library bug leak a stack trace or token.
                    deliverError(
                        callback,
                        AgilJoinException.Network("join request failed unexpectedly"),
                    )
                    return@submit
                }
                deliverSuccess(callback, result)
            }
        } catch (_: RejectedExecutionException) {
            deliverError(callback, AgilJoinException.Closed())
            null
        }
        return AgilJoinHandle(future)
    }

    /**
     * Blocking variant for worker threads.
     *
     * @throws IllegalStateException when called on the Android main thread.
     * @throws AgilJoinException with the same typed failures as the callback API.
     */
    @JvmOverloads
    @Throws(AgilJoinException::class, IllegalStateException::class)
    fun joinBlocking(
        roomId: String,
        request: AgilJoinRequest = AgilJoinRequest(),
    ): AgilJoinResult {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw IllegalStateException("joinBlocking must not be called on the main thread")
        }
        val room = try {
            AgilCallUrl.requireRoom(roomId)
        } catch (error: AgilCallConfigException) {
            throw AgilJoinException.InvalidConfig("room", error.message ?: "invalid room")
        }
        if (closed) throw AgilJoinException.Closed()
        val future = try {
            worker.submit(Callable { executeOrThrow(room, request) })
        } catch (_: RejectedExecutionException) {
            throw AgilJoinException.Closed()
        }
        return try {
            future.get()
        } catch (_: InterruptedException) {
            future.cancel(true)
            Thread.currentThread().interrupt()
            throw AgilJoinException.Cancelled()
        } catch (_: CancellationException) {
            throw AgilJoinException.Cancelled()
        } catch (error: ExecutionException) {
            val cause = error.cause
            if (cause is AgilJoinException) throw cause
            throw AgilJoinException.Network("join request failed unexpectedly", cause)
        }
    }

    /** Stops the owned executor and rejects queued callbacks. Idempotent. */
    override fun close() {
        if (closed) return
        closed = true
        if (ownsExecutor) worker.shutdownNow()
    }

    private fun validatedRoom(roomId: String, callback: AgilJoinCallback): String? = try {
        AgilCallUrl.requireRoom(roomId)
    } catch (error: AgilCallConfigException) {
        deliverError(callback, AgilJoinException.InvalidConfig("room", error.message ?: "invalid room"))
        null
    }

    private fun executeOrThrow(room: String, joinRequest: AgilJoinRequest): AgilJoinResult {
        val endpoint = "$serverUrl/v1/rooms/${encodePathSegment(room)}/join"
        var connection: HttpURLConnection? = null
        try {
            val conn = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = config.connectTimeoutMillis
                readTimeout = config.readTimeoutMillis
                // A redirect could send the request to another host; fail instead.
                instanceFollowRedirects = false
                useCaches = false
                doOutput = true
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("User-Agent", config.userAgent)
                joinRequest.inviteToken?.trim()?.let {
                    setRequestProperty("Authorization", "Bearer $it")
                }
            }
            connection = conn
            val body = JSONObject().apply {
                joinRequest.name?.trim()?.takeIf { it.isNotEmpty() }?.let { put("name", it) }
                joinRequest.password?.let { put("password", it) }
                joinRequest.participantId?.trim()?.takeIf { it.isNotEmpty() }?.let {
                    put("participantId", it)
                }
                // The server schema accepts only `ru`/`en`; normalize regional tags.
                AgilCallUrl.normalizeLanguage(joinRequest.locale)?.let { put("locale", it) }
                joinRequest.identityToken?.trim()?.takeIf { it.isNotEmpty() }?.let {
                    put("identityToken", it)
                }
            }.toString()
            conn.outputStream.use { output ->
                output.write(body.toByteArray(Charsets.UTF_8))
            }
            val status = conn.responseCode
            val stream: InputStream? = if (status in 200..299) {
                conn.inputStream
            } else {
                conn.errorStream
            }
            val response = stream?.let { readLimited(it) }.orEmpty()
            if (status == HTTP_ACCEPTED) {
                // Waiting room: 202 `{pending:true, requestId, ...}` — no token.
                return parsePending(response)
            }
            if (status !in 200..299) throw httpException(status, response)
            return parseResult(response)
        } catch (error: SocketTimeoutException) {
            throw AgilJoinException.Timeout("join request timed out", error)
        } catch (error: InterruptedIOException) {
            if (Thread.currentThread().isInterrupted) {
                throw AgilJoinException.Cancelled()
            }
            throw AgilJoinException.Timeout("join request timed out", error)
        } catch (error: IOException) {
            throw AgilJoinException.Network("network error while joining", error)
        } catch (error: JSONException) {
            throw AgilJoinException.Parse()
        } finally {
            connection?.disconnect()
        }
    }

    private fun parseResult(response: String): AgilJoinResult {
        val json = try {
            JSONObject(response)
        } catch (error: JSONException) {
            throw AgilJoinException.Parse()
        }
        // A 200 with `pending:true`/`status:'pending'` is a waiting-room ticket
        // too (server versions that answer 200 for a lobby request).
        if (json.optBoolean("pending", false) ||
            "pending".equals(jsonString(json, "status"), ignoreCase = true)
        ) {
            return parsePending(json)
        }
        val token = jsonString(json, "token") ?: throw AgilJoinException.Parse(
            "the join response has no token",
        )
        val expiresAt = epochMillis(json, "expiresAt")
        val room = json.optJSONObject("room")?.let { value ->
            val id = jsonString(value, "id") ?: return@let null
            AgilRoom(
                id = id,
                tenantId = jsonString(value, "tenantId"),
                name = jsonString(value, "name"),
                locked = value.optBoolean("locked", false),
            )
        }
        val participant = json.optJSONObject("participant")?.let { value ->
            val id = jsonString(value, "id") ?: return@let null
            AgilParticipant(
                id = id,
                name = jsonString(value, "name"),
                role = jsonString(value, "role"),
            )
        }
        val permissions = json.optJSONArray("permissions")?.let { array ->
            stringList(array)
        }.orEmpty()
        return AgilJoinResult.Joined(
            token = token,
            expiresAtEpochMillis = expiresAt,
            room = room,
            participant = participant,
            permissions = permissions,
        )
    }

    /**
     * Parses a waiting-room ticket: HTTP 202 or a `pending:true` body. Only the
     * documented fields are read; `requestId` is mandatory (it is the lobby poll
     * key), so a 202 without it is still reported as [AgilJoinException.Parse].
     */
    private fun parsePending(response: String): AgilJoinResult.Pending {
        val json = try {
            JSONObject(response)
        } catch (error: JSONException) {
            throw AgilJoinException.Parse("the waiting-room response is malformed")
        }
        return parsePending(json)
    }

    private fun parsePending(json: JSONObject): AgilJoinResult.Pending {
        val requestId = jsonString(json, "requestId")
            ?: throw AgilJoinException.Parse("the waiting-room response has no requestId")
        val status = jsonString(json, "status")?.take(64) ?: AgilJoinResult.STATUS_PENDING
        val roomId = jsonString(json, "roomId")
        return AgilJoinResult.Pending(
            requestId = requestId,
            status = status,
            roomId = roomId,
            expiresAtEpochMillis = epochMillis(json, "expiresAt"),
            pollAfterMillis = epochMillis(json, "pollAfterMs"),
        )
    }

    /** Reads an epoch-millis field; ISO-8601 strings and junk become `0`. */
    private fun epochMillis(json: JSONObject, key: String): Long {
        if (!json.has(key) || json.isNull(key)) return 0L
        val value = json.opt(key)
        if (value is Number) {
            val millis = value.toLong()
            return if (millis > 0L) millis else 0L
        }
        val text = jsonString(json, key) ?: return 0L
        text.toLongOrNull()?.let { return if (it > 0L) it else 0L }
        return parseIsoInstant(text)
    }

    private fun parseIsoInstant(text: String): Long = try {
        val instant = java.time.Instant.parse(text)
        if (instant.toEpochMilli() > 0L) instant.toEpochMilli() else 0L
    } catch (_: Exception) {
        // java.time is API 26+ (minSdk 26); an unparsable value is just unknown.
        0L
    }

    private fun httpException(status: Int, response: String): AgilJoinException.Http {
        var code: String? = null
        var message: String? = null
        try {
            val error = JSONObject(response).optJSONObject("error")
            code = error?.let { jsonString(it, "code") }
                ?.let { AgilTokenRedactor.redactText(it).take(64) }
            val rawMessage = error?.let { jsonString(it, "message") }
            if (rawMessage != null) {
                val redacted = AgilTokenRedactor.redactText(rawMessage)
                message = if (redacted.length > 300) redacted.substring(0, 300) else redacted
            }
        } catch (_: JSONException) {
            // A non-JSON error page is not echoed: it could contain a URL/token.
        }
        return AgilJoinException.Http(status, code, message)
    }

    private fun readLimited(input: InputStream): String {
        val builder = StringBuilder()
        var total = 0
        input.bufferedReader(Charsets.UTF_8).use { reader ->
            val buffer = CharArray(8192)
            while (true) {
                val read = reader.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_RESPONSE_CHARS) {
                    throw AgilJoinException.Parse("the join response is too large")
                }
                builder.append(buffer, 0, read)
            }
        }
        return builder.toString()
    }

    private fun deliverSuccess(callback: AgilJoinCallback, result: AgilJoinResult) {
        deliver(callback) { it.onJoined(result) }
    }

    private fun deliverError(
        callback: AgilJoinCallback,
        error: AgilJoinException,
        deliverEvenIfClosed: Boolean = false,
    ) {
        deliver(callback, deliverEvenIfClosed) { it.onError(error) }
    }

    private fun deliver(
        callback: AgilJoinCallback,
        deliverEvenIfClosed: Boolean = false,
        action: (AgilJoinCallback) -> Unit,
    ) {
        try {
            callbacks.execute {
                // A callback for an in-flight request is dropped after close(),
                // except for the terminal `Closed` error, which must settle the
                // caller instead of leaving it waiting forever.
                if (closed && !deliverEvenIfClosed) return@execute
                try {
                    action(callback)
                } catch (_: RuntimeException) {
                    // A host callback must not kill the client executor.
                }
            }
        } catch (_: RejectedExecutionException) {
            // The callback executor is shutting down; drop the notification.
        }
    }

    private fun jsonString(json: JSONObject, key: String): String? {
        if (!json.has(key) || json.isNull(key)) return null
        val value = json.optString(key, "")
        return if (value.isBlank()) null else value
    }

    private fun stringList(array: JSONArray): List<String> {
        val result = ArrayList<String>(array.length())
        for (index in 0 until array.length()) {
            val value = array.optString(index, "")
            if (value.isNotBlank()) result.add(value)
        }
        return result
    }

    private fun encodePathSegment(value: String): String = try {
        URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    } catch (_: Exception) {
        throw IllegalStateException("UTF-8 is not available")
    }

    private class MainThreadExecutor : Executor {
        private val handler = Handler(Looper.getMainLooper())

        override fun execute(command: Runnable) {
            handler.post(command)
        }
    }

    private companion object {
        const val MAX_RESPONSE_CHARS: Int = 262_144

        /** Waiting-room ticket: `{pending:true, requestId, ...}`, no token. */
        const val HTTP_ACCEPTED: Int = 202
    }
}
