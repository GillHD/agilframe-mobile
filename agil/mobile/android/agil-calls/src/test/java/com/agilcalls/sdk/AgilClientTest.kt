package com.agilcalls.sdk

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Join-client behavior against a loopback HTTP server (no Android):
 * the real server shapes for 200/202/4xx, the waiting-room ticket, the OIDC
 * `identityToken` body and the closed-client callback.
 */
class AgilClientTest {
    private val servers = ArrayList<JoinHttpFixture>()
    private val executors = ArrayList<ExecutorService>()

    @After
    fun tearDown() {
        for (server in servers) server.close()
        for (executor in executors) executor.shutdownNow()
    }

    @Test
    fun parsesSuccessfulJoin() {
        val (url, requests) = server(
            200,
            """{"token":"secret-token","expiresAt":1760014400000,
                   "room":{"id":"team-sync","tenantId":"demo","name":"Team sync","locked":false},
                   "participant":{"id":"p-1","name":"Anna","role":"guest"},
                   "permissions":["chat","reactions"]}""",
        )
        val result = join(url, "team-sync", AgilJoinRequest(name = "Anna"))
        assertTrue(result is AgilJoinResult.Joined)
        val joined = result as AgilJoinResult.Joined
        assertEquals("secret-token", joined.token)
        assertEquals(AgilJoinResult.STATUS_JOINED, joined.status)
        assertTrue(joined.isJoined)
        assertFalse(joined.isPending)
        assertEquals(1760014400000L, joined.expiresAtEpochMillis)
        assertEquals("team-sync", joined.room?.id)
        assertEquals("Anna", joined.participant?.name)
        assertEquals(listOf("chat", "reactions"), joined.permissions)
        assertTrue(requests.single().startsWith("POST /v1/rooms/team-sync/join"))
    }

    @Test
    fun parsesWaitingRoomTicketFrom202() {
        val (url, _) = server(
            202,
            """{"pending":true,"requestId":"lobby-7","roomId":"team-sync",
                   "status":"pending","expiresAt":1760014400000,"pollAfterMs":2000}""",
        )
        val result = join(url, "team-sync")
        assertTrue(result is AgilJoinResult.Pending)
        val pending = result as AgilJoinResult.Pending
        assertEquals("lobby-7", pending.requestId)
        assertEquals("team-sync", pending.roomId)
        assertEquals("pending", pending.status)
        assertEquals(1760014400000L, pending.expiresAtEpochMillis)
        assertEquals(2000L, pending.pollAfterMillis)
        assertTrue(pending.isPending)
        assertFalse(pending.isJoined)
        // A waiting-room ticket carries no join token.
        assertNull(pending.token)
        assertTrue(pending.toString().contains("lobby-7"))
        assertTrue(pending.toString().contains("status=pending"))
    }

    @Test
    fun parsesPendingBodyReturnedWithHttp200() {
        val (url, _) = server(200, """{"pending":true,"requestId":"lobby-8","status":"pending"}""")
        val result = join(url, "team-sync")
        assertTrue(result is AgilJoinResult.Pending)
        assertEquals("lobby-8", (result as AgilJoinResult.Pending).requestId)
    }

    @Test
    fun waitingRoomWithoutRequestIdIsParseError() {
        val (url, _) = server(202, """{"pending":true}""")
        val error = joinError(url, "team-sync")
        assertTrue(error is AgilJoinException.Parse)
        assertTrue(error.message.orEmpty().contains("requestId"))
    }

    @Test
    fun successWithoutTokenIsParseError() {
        val (url, _) = server(200, """{"room":{"id":"team-sync"}}""")
        val error = joinError(url, "team-sync")
        assertTrue(error is AgilJoinException.Parse)
        assertTrue(error.message.orEmpty().contains("no token"))
    }

    @Test
    fun mapsHttpErrorsWithoutLeakingSecrets() {
        val (url, _) = server(
            401,
            """{"error":{"code":"password_invalid","message":"bad token=secret-123"}}""",
        )
        val error = joinError(url, "team-sync")
        assertTrue(error is AgilJoinException.Http)
        val http = error as AgilJoinException.Http
        assertEquals(401, http.status)
        assertEquals("password_invalid", http.code)
        assertTrue(http.message.orEmpty().contains("401"))
        assertFalse(http.message.orEmpty().contains("secret-123"))
        assertFalse(http.serverMessage.orEmpty().contains("secret-123"))
    }

    @Test
    fun oidcTenantPathSendsIdentityTokenInJoinBody() {
        val (url, requests) = server(200, """{"token":"oidc-token","permissions":["chat"]}""")
        val result = join(
            url,
            "team-sync",
            AgilJoinRequest(name = "Anna", locale = "en-US", identityToken = "oidc-assertion-1"),
        )
        assertTrue(result is AgilJoinResult.Joined)
        val body = requests.single()
        assertTrue(body.contains("\"identityToken\":\"oidc-assertion-1\""))
        // The server's join schema only accepts `ru`/`en`.
        assertTrue(body.contains("\"locale\":\"en\""))
        assertFalse(body.contains("en-US"))
    }

    @Test
    fun oidcIdentityRequiredIsATypedHttpError() {
        val (url, _) = server(
            401,
            """{"error":{"code":"identity_required","message":"identity required"}}""",
        )
        val error = joinError(url, "team-sync")
        assertTrue(error is AgilJoinException.Http)
        assertEquals("identity_required", (error as AgilJoinException.Http).code)
    }

    @Test
    fun closedClientStillInvokesTheCallback() {
        val (url, _) = server(200, """{"token":"never"}""")
        val client = client(url)
        client.close()
        assertTrue(client.isClosed)
        val error = joinWithClient(client, "team-sync")
        assertNotNull(error)
        assertTrue(error is AgilJoinException.Closed)
    }

    @Test
    fun redirectsAreNotFollowed() {
        val (target, _) = server(200, """{"token":"other"}""")
        val (url, _) = server(302, """{"redirect":true}""", "$target/v1/rooms/team-sync/join")
        val error = joinError(url, "team-sync")
        assertTrue(error is AgilJoinException.Http)
        assertEquals(302, (error as AgilJoinException.Http).status)
    }

    @Test
    fun invalidRoomFailsBeforeAnyRequest() {
        val (url, requests) = server(200, """{"token":"x"}""")
        val error = joinError(url, "bad/room")
        assertTrue(error is AgilJoinException.InvalidConfig)
        assertTrue(requests.isEmpty())
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    private fun client(serverUrl: String): AgilClient {
        val worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "agil-test-join").apply { isDaemon = true }
        }
        executors.add(worker)
        val callbackExecutor = Executor { runnable -> runnable.run() }
        return AgilClient(AgilClientConfig(serverUrl), worker, callbackExecutor)
    }

    private fun join(
        serverUrl: String,
        room: String,
        request: AgilJoinRequest = AgilJoinRequest(),
    ): AgilJoinResult {
        val outcome = attempt(client(serverUrl), room, request)
        if (outcome is AgilJoinException) throw outcome
        return outcome as AgilJoinResult
    }

    private fun joinError(
        serverUrl: String,
        room: String,
        request: AgilJoinRequest = AgilJoinRequest(),
    ): AgilJoinException {
        val outcome = attempt(client(serverUrl), room, request)
        assertTrue("expected an error, got $outcome", outcome is AgilJoinException)
        return outcome as AgilJoinException
    }

    private fun joinWithClient(client: AgilClient, room: String): AgilJoinException? {
        val outcome = attempt(client, room, AgilJoinRequest())
        return outcome as? AgilJoinException
    }

    private fun attempt(
        client: AgilClient,
        room: String,
        request: AgilJoinRequest,
    ): Any {
        val latch = CountDownLatch(1)
        val joinedRef = AtomicReference<AgilJoinResult>()
        val errorRef = AtomicReference<AgilJoinException>()
        client.join(room, request, object : AgilJoinCallback {
            override fun onJoined(result: AgilJoinResult) {
                joinedRef.set(result)
                latch.countDown()
            }

            override fun onError(error: AgilJoinException) {
                errorRef.set(error)
                latch.countDown()
            }
        })
        assertTrue("join callback timed out", latch.await(10, TimeUnit.SECONDS))
        return joinedRef.get() ?: errorRef.get()!!
    }

    private fun server(status: Int, body: String, location: String? = null): Pair<String, List<String>> {
        val fixture = JoinHttpFixture(status, body, location)
        servers.add(fixture)
        return fixture.url() to fixture.requests
    }
}
