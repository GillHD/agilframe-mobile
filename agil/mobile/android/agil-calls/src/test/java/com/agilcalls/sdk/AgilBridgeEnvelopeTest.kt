package com.agilcalls.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Per-load nonce envelope: the only thing that binds a message to the widget
 * top frame, because `addJavascriptInterface` exposes the interface to every
 * frame and native cannot see the calling frame's origin.
 */
class AgilBridgeEnvelopeTest {
    private val nonce = "a".repeat(64)

    @Test
    fun roundTripsTheInnerMessage() {
        val inner = """{"type":"agil:ready","room":"team-sync"}"""
        val wrapped = AgilBridgeEnvelope.wrap(inner, nonce)
        assertTrue(wrapped.contains(AgilBridgeEnvelope.NONCE_FIELD))
        assertTrue(wrapped.contains(AgilBridgeEnvelope.MESSAGE_FIELD))
        assertEquals(inner, AgilBridgeEnvelope.unwrap(wrapped, nonce))
    }

    @Test
    fun rejectsMessagesWithoutTheEnvelope() {
        // A subframe can call window.AgilCallsBridge.postMessage(rawWidgetJson)
        // directly; that raw JSON has no nonce and must be dropped.
        assertNull(AgilBridgeEnvelope.unwrap("""{"type":"agil:ready"}""", nonce))
        assertNull(AgilBridgeEnvelope.unwrap("""{"__agilBridgeNonce":"$nonce"}""", nonce))
        assertNull(AgilBridgeEnvelope.unwrap("""{"message":"{\"type\":\"agil:ready\"}"}""", nonce))
    }

    @Test
    fun rejectsWrongOrMissingEnvelopeNonce() {
        val wrapped = AgilBridgeEnvelope.wrap("""{"type":"agil:ready"}""", nonce)
        assertNull(AgilBridgeEnvelope.unwrap(wrapped, "b".repeat(64)))
        assertNull(AgilBridgeEnvelope.unwrap(wrapped, ""))
        assertNull(AgilBridgeEnvelope.unwrap(wrapped, "a".repeat(63)))
    }

    @Test
    fun rejectsMalformedAndOversizedPayloads() {
        assertNull(AgilBridgeEnvelope.unwrap(null, nonce))
        assertNull(AgilBridgeEnvelope.unwrap("", nonce))
        assertNull(AgilBridgeEnvelope.unwrap("not json", nonce))
        assertNull(AgilBridgeEnvelope.unwrap("[1,2,3]", nonce))
        assertNull(AgilBridgeEnvelope.unwrap("x".repeat(AgilBridgeEnvelope.MAX_CHARS + 1), nonce))
        val nonStringMessage = """{"__agilBridgeNonce":"$nonce","message":{"type":"agil:ready"}}"""
        assertNull(AgilBridgeEnvelope.unwrap(nonStringMessage, nonce))
    }

    @Test
    fun rejectsEmptyInnerMessage() {
        assertNull(AgilBridgeEnvelope.unwrap(AgilBridgeEnvelope.wrap("", nonce), nonce))
    }

    @Test
    fun unwrappedMessageIsWhatTheProtocolParses() {
        val ready = """{"type":"agil:ready","room":"team-sync","capabilities":{"media":true}}"""
        val inner = AgilBridgeEnvelope.unwrap(AgilBridgeEnvelope.wrap(ready, nonce), nonce)
        val parsed = AgilBridgeProtocol.parse(inner ?: "")
        assertTrue(parsed is AgilBridgeProtocol.Message.Ready)
        assertEquals("team-sync", (parsed as AgilBridgeProtocol.Message.Ready).room)

        // A raw message never reaches the parser through the native path.
        assertNull(AgilBridgeEnvelope.unwrap(ready, nonce))
    }

    @Test
    fun noncesAreRandomHexAndUnique() {
        val first = AgilBridgeEnvelope.newNonce()
        val second = AgilBridgeEnvelope.newNonce()
        assertEquals(64, first.length)
        assertTrue(first.matches(Regex("^[0-9a-f]{64}$")))
        assertNotEquals(first, second)
        assertNull(AgilBridgeEnvelope.unwrap(AgilBridgeEnvelope.wrap("x", first), second))
    }
}
