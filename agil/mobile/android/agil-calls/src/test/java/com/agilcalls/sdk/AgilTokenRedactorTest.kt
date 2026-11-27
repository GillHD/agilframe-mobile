package com.agilcalls.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgilTokenRedactorTest {
    @Test
    fun redactsTokenQueryValues() {
        val url = "https://calls.example.com/embed.html?server=https%3A%2F%2Fcalls.example.com" +
            "&room=team-sync&token=super-secret-token&tenant=demo"
        val redacted = AgilTokenRedactor.redactUrl(url)
        assertFalse(redacted.contains("super-secret-token"))
        assertTrue(redacted.contains("token=<redacted>"))
        assertTrue(redacted.contains("room=team-sync"))
        assertTrue(redacted.contains("tenant=demo"))
    }

    @Test
    fun redactsIdentityAccessAndRefreshTokens() {
        val url = "https://x/embed.html?identity_token=abc123&access_token=def456" +
            "&refresh_token=ghi789&room=r"
        val redacted = AgilTokenRedactor.redactUrl(url)
        assertFalse(redacted.contains("abc123"))
        assertFalse(redacted.contains("def456"))
        assertFalse(redacted.contains("ghi789"))
        assertTrue(redacted.contains("refresh_token=<redacted>"))
        assertTrue(redacted.contains("room=r"))
        // camelCase/assignment forms are covered too.
        assertFalse(AgilTokenRedactor.redactText("refresh_token=secret-value").contains("secret-value"))
        assertFalse(AgilTokenRedactor.redactText("refreshToken=secret-value").contains("secret-value"))
    }

    @Test
    fun redactsJwtAndBearerText() {
        val jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature12345"
        val text = "Authorization: Bearer abcdefghijklmnop and token=$jwt"
        val redacted = AgilTokenRedactor.redactText(text)
        assertFalse(redacted.contains(jwt))
        assertFalse(redacted.contains("abcdefghijklmnop"))
        assertTrue(redacted.contains("<redacted>"))
    }

    @Test
    fun redactsPlainAssignments() {
        val redacted = AgilTokenRedactor.redactText("token = topsecret value=keep-me")
        assertFalse(redacted.contains("topsecret"))
        assertTrue(redacted.contains("value=keep-me"))
    }

    @Test
    fun malformedUrlFallsBackToTextRedaction() {
        val redacted = AgilTokenRedactor.redactUrl("not a url token=secret")
        assertFalse(redacted.contains("secret"))
    }

    @Test
    fun redactThrowableCapsLengthAndMasksTokens() {
        val error = IllegalArgumentException("https://x/?token=secret-token")
        val redacted = AgilTokenRedactor.redactThrowable(error, maxLength = 40)
        assertFalse(redacted.contains("secret-token"))
        assertTrue(redacted.length <= 40)
        assertEquals("unknown error", AgilTokenRedactor.redactThrowable(null))
    }

    @Test
    fun joinRequestToStringHidesSecrets() {
        val request = AgilJoinRequest(
            name = "Anna",
            password = "hunter2",
            participantId = "p-1",
            locale = "ru",
            inviteToken = "invite-secret",
            identityToken = "oidc-secret",
        )
        val text = request.toString()
        assertFalse(text.contains("hunter2"))
        assertFalse(text.contains("invite-secret"))
        assertFalse(text.contains("oidc-secret"))
        assertTrue(text.contains("<redacted>"))
        assertTrue(text.contains("Anna"))
    }

    @Test
    fun joinResultToStringHidesToken() {
        val result = AgilJoinResult.Joined(
            token = "secret-jwt",
            expiresAtEpochMillis = 123,
            permissions = listOf("chat"),
        )
        assertFalse(result.toString().contains("secret-jwt"))
        assertTrue(result.toString().contains("<redacted>"))
        assertTrue(result.toString().contains("Joined"))
    }

    @Test
    fun pendingJoinResultHasNoTokenAndKeepsLobbyFields() {
        val pending = AgilJoinResult.Pending(
            requestId = "lobby-1",
            roomId = "team-sync",
            expiresAtEpochMillis = 999,
            pollAfterMillis = 2000,
        )
        assertNull(pending.token)
        assertEquals("pending", pending.status)
        assertTrue(pending.isPending)
        assertFalse(pending.isJoined)
        assertTrue(pending.toString().contains("lobby-1"))
        assertTrue(pending.toString().contains("pollAfterMillis=2000"))
        expectThrows<IllegalArgumentException> { AgilJoinResult.Pending(requestId = " ") }
        expectThrows<IllegalArgumentException> {
            AgilJoinResult.Joined(token = " ")
        }
        expectThrows<IllegalArgumentException> {
            AgilJoinResult.Joined(token = "t".repeat(AgilCallUrl.MAX_TOKEN_LENGTH + 1))
        }
    }

    @Test
    fun httpJoinErrorExposesStatusAndCodeWithoutSecrets() {
        val error = AgilJoinException.Http(
            status = 401,
            code = "password_invalid",
            serverMessage = "wrong password for token=secret",
        )
        assertTrue(error.message.orEmpty().contains("401"))
        assertTrue(error.message.orEmpty().contains("password_invalid"))
        assertFalse(error.message.orEmpty().contains("secret"))
        assertFalse(error.serverMessage.orEmpty().contains("secret"))
        assertTrue(error.serverMessage.orEmpty().contains("<redacted>"))
        assertEquals(401, error.status)
        assertEquals("password_invalid", error.code)
    }

    @Test
    fun joinRequestValidatesInputs() {
        expectThrows<AgilCallConfigException> { AgilJoinRequest(password = "p".repeat(257)) }
        expectThrows<AgilCallConfigException> { AgilJoinRequest(inviteToken = "a b") }
        expectThrows<AgilCallConfigException> { AgilJoinRequest(locale = "english!") }
        expectThrows<AgilCallConfigException> { AgilJoinRequest(locale = "de") }
        expectThrows<AgilCallConfigException> { AgilJoinRequest(identityToken = "a b") }
        expectThrows<AgilCallConfigException> {
            AgilJoinRequest(identityToken = "i".repeat(16_385))
        }
        // Regional locales normalize to the `ru`/`en` values the server accepts.
        assertEquals("en", AgilCallUrl.normalizeLanguage("en-US"))
        assertEquals("ru", AgilCallUrl.normalizeLanguage("ru-RU"))
    }

    private inline fun <reified T : Throwable> expectThrows(block: () -> Unit): T {
        try {
            block()
        } catch (error: Throwable) {
            if (error is T) return error
            throw AssertionError("Expected ${T::class.java.name}, got ${error.javaClass.name}", error)
        }
        throw AssertionError("Expected ${T::class.java.name} to be thrown")
    }
}
