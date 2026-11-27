package com.agilcalls.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AgilLargeRoomTest {
    private fun ids(count: Int, prefix: String = "p"): List<String> =
        (0 until count).map { "$prefix-$it" }

    @Test
    fun limitsDefaultTo200AndClamp() {
        assertEquals(200, AgilLargeRoom.MAX_PARTICIPANTS)
        assertEquals(200, AgilParticipantDigest().maxParticipants)
        assertEquals(200, AgilParticipantDigest(maxParticipants = 5_000).maxParticipants)
        assertEquals(2, AgilParticipantDigest(maxParticipants = 1).maxParticipants)
    }

    @Test
    fun firstSnapshotThenDeltas() {
        val digest = AgilParticipantDigest()
        val snapshot = digest.apply(ids(200), 200)
        assertEquals(AgilParticipantUpdateKind.SNAPSHOT, snapshot?.kind)
        assertEquals(200, snapshot?.ids?.size ?: -1)
        assertEquals(1, snapshot?.revision ?: -1)

        val delta = digest.apply(ids(199) + "newcomer", 200)
        assertEquals(AgilParticipantUpdateKind.DELTA, delta?.kind)
        assertEquals(listOf("newcomer"), delta?.added)
        assertEquals(listOf("p-199"), delta?.removed)
        assertNull(digest.apply(ids(199) + "newcomer", 200))
    }

    @Test
    fun largeChurnResyncsAndOversizedInputTruncates() {
        val digest = AgilParticipantDigest()
        digest.apply(ids(40), 40)
        val resync = digest.apply(ids(20) + ids(20, "q"), 40)
        assertEquals(AgilParticipantUpdateKind.SNAPSHOT, resync?.kind)
        assertEquals(40, resync?.ids?.size ?: -1)

        val oversized = AgilParticipantDigest().apply(ids(260), 260)
        assertEquals(200, oversized?.ids?.size ?: -1)
        assertEquals(true, oversized?.truncated == true)
        assertEquals(260, oversized?.count ?: -1)
    }

    @Test
    fun countOnlySnapshotIsSummary() {
        val digest = AgilParticipantDigest()
        assertEquals(AgilParticipantUpdateKind.SUMMARY, digest.apply(null, 180)?.kind)
        assertNull(digest.apply(null, 180))
        assertEquals(179, digest.apply(null, 179)?.count ?: -1)
    }

    @Test
    fun connectionDigestDeduplicatesReconnect() {
        val digest = AgilConnectionDigest()
        assertEquals(AgilConnectionState.CONNECTED, digest.apply("connected", null, null)?.state)
        val reconnecting = digest.apply("reconnecting", 2, 1_000)
        assertEquals(true, reconnecting?.reconnecting == true)
        assertEquals(2, reconnecting?.attempt ?: -1)
        assertNull(digest.apply("reconnecting", 2, 1_000))
        assertEquals(AgilConnectionState.RECONNECTING, digest.apply("connected", null, null)?.previous)
        assertEquals(AgilConnectionState.CONNECTED, AgilConnectionState.fromWire("OPEN"))
    }

    @Test
    fun configValidatesMaxParticipantsAndPreservesTokens() {
        val config = AgilCallConfig(
            serverUrl = "https://calls.example.com",
            room = "large-room",
            token = "token-1",
            identityToken = "identity-1",
            maxParticipants = 200,
        )
        assertEquals(200, config.maxParticipants)
        assertEquals("token-1", config.token)
        assertEquals("identity-1", config.identityToken)
        assertEquals("https://calls.example.com", config.serverOrigin)
        assertTrue(config.toString().contains("token=REDACTED") || !config.toString().contains("token-1"))

        assertThrows(AgilCallConfigException::class.java) {
            AgilCallConfig(serverUrl = "https://calls.example.com", room = "r", maxParticipants = 201)
        }
        assertThrows(AgilCallConfigException::class.java) {
            AgilCallConfig(serverUrl = "https://calls.example.com", room = "r", maxParticipants = 1)
        }
    }

    @Test
    fun countOnlyBridgeStateProducesSummary() {
        val message = AgilBridgeProtocol.parse(
            """{"type":"agil:state","state":{"phase":"joined","participants":180}}""",
        )
        assertTrue(message is AgilBridgeProtocol.Message.State)
        val snapshot = (message as AgilBridgeProtocol.Message.State).snapshot
        assertEquals(false, snapshot.hasParticipantIds)

        // Mirrors AgilCallView: absent ids must be passed as null, not [].
        val digest = AgilParticipantDigest()
        val update = digest.apply(
            if (snapshot.hasParticipantIds) snapshot.participantIds else null,
            snapshot.participants,
        )
        assertEquals(AgilParticipantUpdateKind.SUMMARY, update?.kind)
        assertEquals(180, update?.count ?: -1)
        assertNull(
            digest.apply(
                if (snapshot.hasParticipantIds) snapshot.participantIds else null,
                snapshot.participants,
            ),
        )
    }

    @Test
    fun emptyParticipantIdsIsASnapshotNotASummary() {
        val message = AgilBridgeProtocol.parse(
            """{"type":"agil:state","state":{"phase":"joined","participants":0,"participantIds":[]}}""",
        )
        val snapshot = (message as AgilBridgeProtocol.Message.State).snapshot
        assertEquals(true, snapshot.hasParticipantIds)
        val digest = AgilParticipantDigest()
        val update = digest.apply(
            if (snapshot.hasParticipantIds) snapshot.participantIds else null,
            snapshot.participants,
        )
        assertEquals(AgilParticipantUpdateKind.SNAPSHOT, update?.kind)
        assertEquals(0, update?.ids?.size ?: -1)
    }

    @Test
    fun compactStateMatchesTheJsContract() {
        val digest = AgilParticipantDigest()
        val snapshot = AgilCallSnapshot(
            phase = "joined",
            participants = 200,
            participantIds = ids(200),
            hasParticipantIds = true,
        )
        val first = snapshot.compactForParticipantUpdate(digest.apply(ids(200), 200))
        assertEquals(emptyList<String>(), first.participantIds)
        assertEquals(false, first.hasParticipantIds)
        assertEquals(200, first.participantCount ?: -1)
        assertEquals(1, first.participantRevision ?: -1)

        val delta = snapshot.compactForParticipantUpdate(digest.apply(ids(199) + "newcomer", 200))
        assertEquals(emptyList<String>(), delta.participantIds)
        assertEquals(200, delta.participantCount ?: -1)
        assertEquals(2, delta.participantRevision ?: -1)

        val unchanged = snapshot.compactForParticipantUpdate(digest.apply(ids(199) + "newcomer", 200))
        assertNull(unchanged.participantCount)
        assertNull(unchanged.participantRevision)
    }
}
