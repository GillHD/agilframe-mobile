package com.agilcalls.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM parsing of the documented `agil:*` widget messages. */
class AgilBridgeProtocolTest {
    @Test
    fun parsesReadyWithCapabilities() {
        val message = AgilBridgeProtocol.parse(
            """{"type":"agil:ready","room":"team-sync",
               "capabilities":{"media":true,"blur":true,"screenShare":false,
                               "captions":true,"recording":false}}""",
        )
        assertTrue(message is AgilBridgeProtocol.Message.Ready)
        val ready = message as AgilBridgeProtocol.Message.Ready
        assertEquals("team-sync", ready.room)
        assertTrue(ready.capabilities.media)
        assertTrue(ready.capabilities.blur)
        assertEquals(false, ready.capabilities.screenShare)
        assertTrue(ready.capabilities.captions)
    }

    @Test
    fun parsesChatObjectAndPlainString() {
        val objectMessage = AgilBridgeProtocol.parse(
            """{"type":"agil:chat","message":{"text":"hi","id":"m-1",
               "participantId":"p-1","participantName":"Anna","ts":1760014400000}}""",
        )
        assertTrue(objectMessage is AgilBridgeProtocol.Message.Chat)
        val chat = (objectMessage as AgilBridgeProtocol.Message.Chat).message
        assertEquals("hi", chat.text)
        assertEquals("m-1", chat.id)
        assertEquals("Anna", chat.participantName)
        assertEquals(1760014400000L, chat.timestamp)

        val stringMessage = AgilBridgeProtocol.parse("""{"type":"agil:chat","message":"hello"}""")
        assertEquals("hello", (stringMessage as AgilBridgeProtocol.Message.Chat).message.text)
    }

    @Test
    fun parsesStateSnapshot() {
        val message = AgilBridgeProtocol.parse(
            """{"type":"agil:state","state":{"phase":"joined","participants":3,
               "participantIds":["p-1","p-2","p-3"],
               "quality":{"tier":"good","score":4.5},"connectionState":"connected",
               "recording":true,"minimized":false,"chatMode":"open","fullscreen":true,
               "settings":{"mic":true,"camera":false,"screen":false,
                           "blur":"off","panel":"chat"}}}""",
        )
        assertTrue(message is AgilBridgeProtocol.Message.State)
        val snapshot = (message as AgilBridgeProtocol.Message.State).snapshot
        assertEquals("joined", snapshot.phase)
        assertEquals(3, snapshot.participants)
        assertEquals(listOf("p-1", "p-2", "p-3"), snapshot.participantIds)
        assertEquals("good", snapshot.qualityTier)
        assertEquals(4.5, snapshot.qualityScore)
        assertEquals(true, snapshot.recording)
        assertEquals(true, snapshot.fullscreen)
        assertEquals(true, snapshot.micEnabled)
        assertEquals(false, snapshot.cameraEnabled)
        assertEquals("chat", snapshot.panel)
    }

    @Test
    fun parsesEventAndKeepsPayload() {
        val message = AgilBridgeProtocol.parse(
            """{"type":"agil:event","event":"joined","payload":{"room":{"id":"r"},"self":null}}""",
        )
        assertTrue(message is AgilBridgeProtocol.Message.Event)
        val event = message as AgilBridgeProtocol.Message.Event
        assertEquals("joined", event.name)
        assertEquals("r", event.payload?.optJSONObject("room")?.optString("id"))
        assertNotNull(event.payloadJson)
    }

    @Test
    fun parsesWidgetFatalErrorFlag() {
        val message = AgilBridgeProtocol.parse(
            """{"type":"agil:event","event":"error",
               "payload":{"code":"signaling-failed","message":"socket failed","fatal":true}}""",
        )
        val event = message as AgilBridgeProtocol.Message.Event
        assertEquals("error", event.name)
        assertEquals(true, event.payload?.optBoolean("fatal", false))
    }

    @Test
    fun parsesMinimizedAndFullscreen() {
        val minimized = AgilBridgeProtocol.parse("""{"type":"agil:minimized","minimized":true}""")
        assertEquals("minimized", (minimized as AgilBridgeProtocol.Message.Event).name)
        assertEquals("true", minimized.payloadJson)

        val fullscreen = AgilBridgeProtocol.parse("""{"type":"agil:fullscreen","fullscreen":false}""")
        assertEquals("fullscreen", (fullscreen as AgilBridgeProtocol.Message.Event).name)
    }

    @Test
    fun rejectsMalformedOversizedAndUnknownMessages() {
        assertNull(AgilBridgeProtocol.parse(""))
        assertNull(AgilBridgeProtocol.parse("not json"))
        assertNull(AgilBridgeProtocol.parse("[]"))
        assertNull(AgilBridgeProtocol.parse("""{"type":"agil:unknown"}"""))
        assertNull(AgilBridgeProtocol.parse("""{"type":"agil:event","event":"BAD NAME"}"""))
        assertNull(
            AgilBridgeProtocol.parse(
                "x".repeat(AgilBridgeProtocol.MAX_MESSAGE_CHARS + 1),
            ),
        )
    }
}
