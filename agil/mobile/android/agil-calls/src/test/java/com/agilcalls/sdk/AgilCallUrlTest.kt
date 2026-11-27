package com.agilcalls.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgilCallUrlTest {
    private val server = "https://calls.example.com"

    @Test
    fun buildsRootEmbedUrl() {
        val target = AgilCallUrl.build(
            serverUrl = server,
            room = "team-sync",
            token = "jwt-token-123",
        )
        assertEquals(
            "https://calls.example.com/embed.html" +
                "?server=https%3A%2F%2Fcalls.example.com&room=team-sync" +
                "&token=jwt-token-123&tenant=demo",
            target.url,
        )
        assertEquals("https://calls.example.com", target.origin)
        assertEquals(server, target.serverUrl)
    }

    @Test
    fun preservesServerSubpathForRelativeWidgetPath() {
        val target = AgilCallUrl.build(
            serverUrl = "https://calls.example.com/calls/",
            room = "team-sync",
        )
        assertTrue(target.url.startsWith("https://calls.example.com/calls/embed.html?"))
        assertTrue(target.url.contains("server=https%3A%2F%2Fcalls.example.com%2Fcalls"))
        assertEquals("https://calls.example.com", target.origin)
    }

    @Test
    fun absoluteWidgetPathAddressesOriginRoot() {
        val target = AgilCallUrl.build(
            serverUrl = "https://calls.example.com/calls",
            room = "team-sync",
            widgetPath = "/embed.html",
        )
        assertTrue(target.url.startsWith("https://calls.example.com/embed.html?"))
    }

    @Test
    fun encodesOptionalParameters() {
        val target = AgilCallUrl.build(
            serverUrl = server,
            room = "team sync",
            token = "a+b/c=",
            tenant = "acme",
            participantName = "Anna Smith",
            language = "en-US",
            theme = AgilTheme.DARK,
            relayOnly = true,
        )
        assertTrue(target.url.contains("room=team+sync"))
        assertTrue(target.url.contains("token=a%2Bb%2Fc%3D"))
        assertTrue(target.url.contains("name=Anna+Smith"))
        // The widget/server only understand `ru`/`en`; `en-US` is normalized.
        assertTrue(target.url.contains("lang=en&"))
        assertFalse(target.url.contains("lang=en-US"))
        assertTrue(target.url.contains("theme=dark"))
        assertTrue(target.url.contains("relay=1"))
        assertTrue(target.url.contains("tenant=acme"))
    }

    @Test
    fun buildsIdentityTokenAndRoleParams() {
        val target = AgilCallUrl.build(
            serverUrl = server,
            room = "team-sync",
            token = "join-token",
            identityToken = "oidc-assertion-1",
            role = AgilRole.MODERATOR,
        )
        assertTrue(target.url.contains("identity_token=oidc-assertion-1"))
        assertTrue(target.url.contains("role=moderator"))
        assertTrue(target.url.contains("token=join-token"))
        // Both secrets are masked in the redacted URL.
        assertFalse(target.redactedUrl.contains("oidc-assertion-1"))
        assertFalse(target.redactedUrl.contains("join-token"))
        assertTrue(target.redactedUrl.contains("identity_token=<redacted>"))
    }

    @Test
    fun rejectsInvalidIdentityToken() {
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", identityToken = "id token with spaces")
        }
        val error = expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", identityToken = "i".repeat(16_385))
        }
        assertEquals("identityToken", error.field)
    }

    @Test
    fun normalizesLanguageToRuOrEn() {
        assertEquals("en", AgilCallUrl.build(server, "room", language = "en-US").url
            .substringAfter("lang=").substringBefore('&'))
        assertEquals("ru", AgilCallUrl.build(server, "room", language = "RU-ru").url
            .substringAfter("lang=").substringBefore('&'))
        assertEquals(null, AgilCallUrl.normalizeLanguage("  "))
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", language = "de")
        }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", language = "english!")
        }
    }

    @Test
    fun rejectsNonNumericLoopbackDevelopmentHosts() {
        // `127.evil.com` / `127.0.0.1.nip.io` are DNS names, not loopback.
        expectThrows<AgilCallConfigException> { AgilCallUrl.build("http://127.evil.com", "room") }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build("http://127.0.0.1.nip.io:8080", "room")
        }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.parseOrigin("http://127.evil.com")
        }
        // A numeric 127.0.0.0/8 literal is loopback: HTTP is allowed.
        assertTrue(AgilCallUrl.build("http://127.0.0.1:8787", "room").url.startsWith("http://"))
        assertTrue(AgilCallUrl.build("http://127.0.0.2:8787", "room").url.startsWith("http://"))
        assertTrue(AgilCallUrl.build("http://localhost:8787", "room").url.startsWith("http://"))
    }

    @Test
    fun rejectsPercentEncodedWidgetPathTraversal() {
        val invalid = listOf(
            "%2e%2e/embed.html",
            "%2E%2E/embed.html",
            "a/%2e%2e/embed.html",
            "calls/%2e%2e/%2e%2e/embed.html",
            "embed%2f..%2fsecret.html",
            "embed%5c..%5csecret.html",
            ".%2e/embed.html",
        )
        for (value in invalid) {
            val error = expectThrows<AgilCallConfigException> {
                AgilCallUrl.build("https://calls.example.com/calls", "room", widgetPath = value)
            }
            assertEquals("widgetPath", error.field)
        }
        // Legitimate percent-encoding still works, including inside a subpath.
        assertTrue(
            AgilCallUrl.build(server, "room", widgetPath = "embed%2Dcustom.html")
                .url.startsWith("https://calls.example.com/embed%2Dcustom.html?"),
        )
        assertTrue(
            AgilCallUrl.build(
                "https://calls.example.com/calls",
                "room",
                widgetPath = "widgets%2Dv2/embed.html",
            ).url.startsWith("https://calls.example.com/calls/widgets%2Dv2/embed.html?"),
        )
    }

    @Test
    fun rejectsPercentEncodedServerPathTraversal() {
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.normalizeServerUrl("https://calls.example.com/a/%2e%2e/b")
        }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.normalizeServerUrl("https://calls.example.com/a%2f..%2fb")
        }
    }

    @Test
    fun normalizesServerOriginAndDefaultPort() {
        assertEquals("https://example.com", AgilCallUrl.originOf("https://EXAMPLE.com:443/"))
        assertEquals("https://example.com", AgilCallUrl.normalizeServerUrl("https://example.com:443/"))
        assertEquals("https://example.com/calls", AgilCallUrl.normalizeServerUrl("https://example.com/calls/"))
        assertEquals("http://10.0.2.2:8787", AgilCallUrl.normalizeServerUrl("http://10.0.2.2:8787/"))
    }

    @Test
    fun allowsHttpOnlyForDevelopmentHosts() {
        assertTrue(AgilCallUrl.build("http://localhost:8787", "room").url.startsWith("http://localhost:8787/"))
        assertTrue(AgilCallUrl.build("http://10.0.2.2:8787", "room").url.startsWith("http://10.0.2.2:8787/"))
        assertTrue(AgilCallUrl.build("http://127.0.0.1:8787", "room").url.startsWith("http://127.0.0.1:8787/"))
        val error = expectThrows<AgilCallConfigException> {
            AgilCallUrl.build("http://calls.example.com", "room")
        }
        assertEquals("serverUrl", error.field)
        assertTrue(AgilCallUrl.build("http://calls.example.com", "room", allowInsecure = true).url.startsWith("http://"))
    }

    @Test
    fun rejectsUnsafeServerUrls() {
        val invalid = listOf(
            "",
            "not a url",
            "javascript:alert(1)",
            "file:///tmp/embed.html",
            "data:text/html,hi",
            "ws://calls.example.com",
            "https://user:pass@calls.example.com",
            "https://calls.example.com?token=abc",
            "https://calls.example.com#fragment",
            "https://calls.example.com/a/../b",
        )
        for (value in invalid) {
            expectThrows<AgilCallConfigException> { AgilCallUrl.build(value, "room") }
        }
    }

    @Test
    fun rejectsUnsafeWidgetPaths() {
        val invalid = listOf(
            "",
            "../embed.html",
            "a/../embed.html",
            "https://evil.example/embed.html",
            "//evil.example/embed.html",
            "embed.html?x=1",
            "embed.html#x",
            "embed\\html",
            "/",
        )
        for (value in invalid) {
            expectThrows<AgilCallConfigException> {
                AgilCallUrl.build(server, "room", widgetPath = value)
            }
        }
    }

    @Test
    fun rejectsInvalidRoomTokenNameAndLanguage() {
        expectThrows<AgilCallConfigException> { AgilCallUrl.build(server, " ") }
        expectThrows<AgilCallConfigException> { AgilCallUrl.build(server, "r".repeat(201)) }
        expectThrows<AgilCallConfigException> { AgilCallUrl.build(server, "..") }
        expectThrows<AgilCallConfigException> { AgilCallUrl.build(server, "a/b") }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", token = "secret token")
        }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", token = "token".repeat(2000))
        }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", participantName = "n".repeat(121))
        }
        expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", language = "english!")
        }
    }

    @Test
    fun errorMessagesNeverContainTokenValues() {
        val error = expectThrows<AgilCallConfigException> {
            AgilCallUrl.build(server, "room", token = "super-secret-token with space")
        }
        assertFalse(error.message.orEmpty().contains("super-secret-token"))
        val target = AgilCallUrl.build(server, "room", token = "super-secret-token")
        assertFalse(target.toString().contains("super-secret-token"))
        assertFalse(target.redactedUrl.contains("super-secret-token"))
        assertTrue(target.redactedUrl.contains("<redacted>"))
    }

    @Test
    fun parsesExactOrigins() {
        assertEquals("https://sso.example.com", AgilCallUrl.parseOrigin("https://sso.example.com:443/"))
        assertEquals("http://localhost:9000", AgilCallUrl.parseOrigin("http://localhost:9000"))
        assertEquals(
            listOf("https://sso.example.com", "https://id.example.com"),
            AgilCallUrl.parseAllowedOrigins(
                listOf("https://sso.example.com", "https://id.example.com:443"),
            ),
        )
        val invalid = listOf(
            "*",
            "https://*.example.com",
            "https://sso.example.com/login",
            "https://sso.example.com?x=1",
            "https://user:pass@sso.example.com",
            "http://sso.example.com",
            "javascript:alert(1)",
            "",
        )
        for (value in invalid) {
            expectThrows<AgilCallConfigException> { AgilCallUrl.parseOrigin(value) }
        }
    }

    @Test
    fun rejectsTooManyAllowedOrigins() {
        val entries = (1..17).map { "https://sso$it.example.com" }
        expectThrows<AgilCallConfigException> { AgilCallUrl.parseAllowedOrigins(entries) }
    }

    @Test
    fun navigationGuardAllowsOnlyServerAndExactAllowlist() {
        val allowed = listOf("https://sso.example.com")
        assertTrue(AgilCallUrl.isAllowedNavigation("about:blank", server, allowed))
        assertTrue(AgilCallUrl.isAllowedNavigation("https://calls.example.com/embed.html?x=1", server, allowed))
        assertTrue(AgilCallUrl.isAllowedNavigation("https://sso.example.com/login?next=x", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("https://evil.example/embed.html", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("https://calls.example.com.evil.example/", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("https://calls.example.com:444/", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("https://user@calls.example.com/", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("https://calls.example.com@evil.example/", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("javascript:alert(1)", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("file:///sdcard/embed.html", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("intent://scan/#Intent;end", server, allowed))
        assertFalse(AgilCallUrl.isAllowedNavigation("data:text/html,hi", server, allowed))
    }

    @Test
    fun originOfUrlRejectsUnsafeValues() {
        assertEquals("https://calls.example.com", AgilCallUrl.originOfUrl("https://calls.example.com/x?y=1"))
        assertEquals("http://localhost:8787", AgilCallUrl.originOfUrl("http://localhost:8787/x"))
        assertEquals(null, AgilCallUrl.originOfUrl("javascript:alert(1)"))
        assertEquals(null, AgilCallUrl.originOfUrl("https://user:pass@calls.example.com"))
        assertEquals(null, AgilCallUrl.originOfUrl("not a url"))
    }

    @Test
    fun configRedactsTokenAndBuildsTarget() {
        val config = AgilCallConfig(
            serverUrl = server,
            room = "team-sync",
            token = "secret-jwt-token",
            participantName = "Anna",
            theme = AgilTheme.AUTO,
        )
        assertFalse(config.toString().contains("secret-jwt-token"))
        assertTrue(config.toString().contains("<redacted>"))
        assertEquals("https://calls.example.com", config.serverOrigin)
        assertEquals(listOf("https://calls.example.com"), config.origins)
        assertTrue(config.toTarget().url.contains("token=secret-jwt-token"))
    }

    @Test
    fun configCarriesIdentityTokenAndRole() {
        val config = AgilCallConfig(
            serverUrl = server,
            room = "team-sync",
            identityToken = "oidc-secret-assertion",
            role = AgilRole.HOST,
            language = "ru-RU",
            allowedOrigins = listOf("https://sso.example.com", "https://sso.example.com"),
        )
        assertFalse(config.toString().contains("oidc-secret-assertion"))
        assertTrue(config.toString().contains("identityToken=<redacted>"))
        assertTrue(config.toString().contains("role=HOST"))
        val target = config.toTarget()
        assertTrue(target.url.contains("identity_token=oidc-secret-assertion"))
        assertTrue(target.url.contains("role=host"))
        assertTrue(target.url.contains("lang=ru"))
        assertFalse(target.redactedUrl.contains("oidc-secret-assertion"))
        // Allowlist duplicates are collapsed.
        assertEquals(listOf("https://calls.example.com", "https://sso.example.com"), config.origins)
    }

    @Test
    fun configRejectsInvalidIdentityToken() {
        val error = expectThrows<AgilCallConfigException> {
            AgilCallConfig(serverUrl = server, room = "room", identityToken = "has space")
        }
        assertEquals("identityToken", error.field)
        assertFalse(error.message.orEmpty().contains("has space"))
    }

    @Test
    fun roleWireValuesMatchContract() {
        assertEquals("host", AgilRole.HOST.wire)
        assertEquals("moderator", AgilRole.MODERATOR.wire)
        assertEquals("guest", AgilRole.GUEST.wire)
        assertEquals(AgilRole.MODERATOR, AgilRole.fromWire("MODERATOR"))
        assertEquals(null, AgilRole.fromWire("admin"))
    }

    @Test
    fun configRejectsInvalidTimeoutAndOrigins() {
        expectThrows<AgilCallConfigException> {
            AgilCallConfig(serverUrl = server, room = "room", bridgeTimeoutMillis = -1)
        }
        expectThrows<AgilCallConfigException> {
            AgilCallConfig(
                serverUrl = server,
                room = "room",
                allowedOrigins = listOf("*"),
            )
        }
        expectThrows<AgilCallConfigException> {
            AgilCallConfig(serverUrl = "http://calls.example.com", room = "room")
        }
    }

    @Test
    fun themeWireValuesMatchEmbedContract() {
        assertEquals("light", AgilTheme.LIGHT.wire)
        assertEquals("dark", AgilTheme.DARK.wire)
        assertEquals("auto", AgilTheme.AUTO.wire)
        assertEquals(AgilTheme.DARK, AgilTheme.fromWire("DARK"))
        assertEquals(null, AgilTheme.fromWire("corporate"))
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
