import Foundation
import XCTest
@testable import AgilCallsSDK

final class AgilBridgeTests: XCTestCase {
    func testReadyMessage() throws {
        let payload = TestSupport.jsonString([
            "type": "agil:ready",
            "capabilities": [
                "media": true,
                "blur": false,
                "screenShare": true,
                "captions": false,
                "recording": true
            ],
            "room": "demo",
            "server": "https://calls.example.com"
        ])
        let event = try XCTUnwrap(AgilBridge.parse(payload))
        guard case .ready(let info) = event else {
            return XCTFail("Expected ready, got \(event)")
        }
        XCTAssertEqual(info.room, "demo")
        XCTAssertEqual(info.server, "https://calls.example.com")
        XCTAssertTrue(info.capabilities.media)
        XCTAssertFalse(info.capabilities.blur)
        XCTAssertTrue(info.capabilities.screenShare)
        XCTAssertTrue(info.capabilities.recording)
    }

    func testJoinedAndLeftMessages() throws {
        let joined = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:event",
            "event": "joined",
            "payload": ["participantId": "p1"]
        ])))
        guard case .joined(let payload) = joined else {
            return XCTFail("Expected joined")
        }
        XCTAssertEqual(payload?["participantId"]?.stringValue, "p1")

        let left = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:event",
            "event": "left"
        ])))
        guard case .left = left else {
            return XCTFail("Expected left")
        }
    }

    func testChatMessageObject() throws {
        let event = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:chat",
            "message": [
                "text": "hello",
                "id": "m1",
                "participantId": "p1",
                "participantName": "Alice",
                "ts": 1_760_000_000_000
            ]
        ])))
        guard case .chat(let message) = event else {
            return XCTFail("Expected chat")
        }
        XCTAssertEqual(message.text, "hello")
        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.participantId, "p1")
        XCTAssertEqual(message.participantName, "Alice")
        let timestamp = try XCTUnwrap(message.timestamp)
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_760_000_000, accuracy: 0.001)
    }

    func testChatMessageStringAndTruncation() throws {
        let event = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:chat",
            "message": String(repeating: "a", count: 4_500)
        ])))
        guard case .chat(let message) = event else {
            return XCTFail("Expected chat")
        }
        XCTAssertEqual(message.text.count, AgilBridge.maxChatCharacters)
    }

    func testStateSnapshot() throws {
        let event = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:state",
            "state": [
                "phase": "joined",
                "participants": 2,
                "participantIds": ["a", "b"],
                "quality": ["tier": "good", "score": 4.5],
                "connectionState": "connected",
                "recording": true,
                "minimized": false,
                "chatMode": "builtin",
                "fullscreen": false,
                "layoutMode": "grid",
                "settings": [
                    "mic": true,
                    "camera": false,
                    "screen": false,
                    "blur": "off",
                    "panel": "chat"
                ]
            ]
        ])))
        guard case .state(let state) = event else {
            return XCTFail("Expected state")
        }
        XCTAssertEqual(state.phase, "joined")
        XCTAssertEqual(state.participants, 2)
        XCTAssertEqual(state.participantIds, ["a", "b"])
        XCTAssertEqual(state.qualityTier, "good")
        XCTAssertEqual(state.qualityScore, 4.5)
        XCTAssertEqual(state.connectionState, "connected")
        XCTAssertEqual(state.recording, true)
        XCTAssertEqual(state.minimized, false)
        XCTAssertEqual(state.chatMode, "builtin")
        XCTAssertEqual(state.fullscreen, false)
        XCTAssertEqual(state.layoutMode, "grid")
        XCTAssertEqual(state.microphoneEnabled, true)
        XCTAssertEqual(state.cameraEnabled, false)
        XCTAssertEqual(state.screenSharing, false)
        XCTAssertEqual(state.blurMode, "off")
        XCTAssertEqual(state.panel, "chat")
    }

    func testMinimizedAndFullscreenMessages() throws {
        let minimized = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:minimized",
            "minimized": true
        ])))
        guard case .minimized(let value) = minimized else {
            return XCTFail("Expected minimized")
        }
        XCTAssertTrue(value)

        let fullscreen = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:fullscreen",
            "fullscreen": true
        ])))
        guard case .fullscreen(let value) = fullscreen else {
            return XCTFail("Expected fullscreen")
        }
        XCTAssertTrue(value)
    }

    func testWidgetErrorIsRedacted() throws {
        let event = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:event",
            "event": "error",
            "payload": [
                "code": "mount_failed",
                "message": "failed with token=super-secret",
                "fatal": true
            ]
        ])))
        guard case .error(let failure) = event else {
            return XCTFail("Expected error")
        }
        XCTAssertEqual(failure.code, .widgetError)
        XCTAssertEqual(failure.widgetCode, "mount_failed")
        XCTAssertTrue(failure.fatal)
        XCTAssertFalse(failure.message.contains("super-secret"))
        XCTAssertTrue(failure.message.contains("token=redacted"))
    }

    func testGenericEvent() throws {
        let event = try XCTUnwrap(AgilBridge.parse(TestSupport.jsonString([
            "type": "agil:event",
            "event": "quality-changed",
            "payload": ["tier": "good"]
        ])))
        guard case .event(let name, let payload) = event else {
            return XCTFail("Expected generic event")
        }
        XCTAssertEqual(name, "quality-changed")
        XCTAssertEqual(payload?["tier"]?.stringValue, "good")
    }

    func testPongAndUnknownMessagesAreIgnored() {
        XCTAssertNil(AgilBridge.parse(TestSupport.jsonString(["type": "agil:pong"])))
        XCTAssertNil(AgilBridge.parse(TestSupport.jsonString(["type": "agil:unknown"])))
        XCTAssertNil(AgilBridge.parse(TestSupport.jsonString(["type": "other"])))
        XCTAssertNil(AgilBridge.parse("not json"))
        XCTAssertNil(AgilBridge.parse(""))
        XCTAssertNil(AgilBridge.parse(TestSupport.jsonString(["type": "agil:event", "event": "UPPER"])))
    }

    func testOversizedPayloadIsRejected() {
        let room = String(repeating: "x", count: AgilBridge.maxMessageBytes)
        let payload = TestSupport.jsonString([
            "type": "agil:ready",
            "capabilities": [:],
            "room": room
        ])
        XCTAssertGreaterThan(payload.utf8.count, AgilBridge.maxMessageBytes)
        XCTAssertNil(AgilBridge.parse(payload))
    }

    func testPrototypeKeysAreDropped() throws {
        let event = try XCTUnwrap(AgilBridge.parse([
            "type": "agil:event",
            "event": "custom",
            "payload": [
                "__proto__": ["polluted": true],
                "prototype": ["polluted": true],
                "constructor": ["polluted": true],
                "safe": true
            ]
        ] as [String: Any]))
        guard case .event(_, let payload) = event,
              let object = payload?.objectValue else {
            return XCTFail("Expected generic event with object payload")
        }
        XCTAssertNil(object["__proto__"])
        XCTAssertNil(object["prototype"])
        XCTAssertNil(object["constructor"])
        XCTAssertEqual(object["safe"]?.boolValue, true)
    }

    func testChatMessageFromWidgetSenderObject() throws {
        let nonce = "test-nonce"
        let event = try XCTUnwrap(AgilBridge.parse(
            TestSupport.bridgeEnvelope([
                "type": "agil:chat",
                "message": [
                    "id": "m1",
                    "roomId": "demo",
                    "from": ["id": "p1", "name": "Alice", "role": "guest"],
                    "text": "hello",
                    "ts": 1_760_000_000_000,
                    "kind": "text"
                ]
            ], nonce: nonce),
            nonce: nonce
        ))
        guard case .chat(let message) = event else {
            return XCTFail("Expected chat")
        }
        XCTAssertEqual(message.text, "hello")
        XCTAssertEqual(message.participantId, "p1")
        XCTAssertEqual(message.participantName, "Alice")
        XCTAssertEqual(message.raw?["from"]?["role"]?.stringValue, "guest")
    }

    func testChatMessageFlatFieldsWinOverSenderObject() throws {
        let nonce = "test-nonce"
        let event = try XCTUnwrap(AgilBridge.parse(
            TestSupport.bridgeEnvelope([
                "type": "agil:chat",
                "message": [
                    "text": "hello",
                    "participantId": "flat-id",
                    "participantName": "Flat Name",
                    "from": ["id": "p1", "name": "Alice", "role": "guest"]
                ]
            ], nonce: nonce),
            nonce: nonce
        ))
        guard case .chat(let message) = event else {
            return XCTFail("Expected chat")
        }
        XCTAssertEqual(message.participantId, "flat-id")
        XCTAssertEqual(message.participantName, "Flat Name")
    }

    func testNonceEnvelopeIsRequiredForNativeMessages() {
        let nonce = "test-nonce"
        let raw = TestSupport.jsonString([
            "type": "agil:ready",
            "capabilities": ["media": true]
        ])
        XCTAssertNil(AgilBridge.parse(raw, nonce: nonce))
        XCTAssertNil(AgilBridge.parse(
            TestSupport.bridgeEnvelope(["type": "agil:ready"], nonce: "other-nonce"),
            nonce: nonce
        ))
        XCTAssertNil(AgilBridge.parse(
            TestSupport.bridgeEnvelope(["type": "agil:ready"], nonce: nonce),
            nonce: ""
        ))
        XCTAssertNotNil(AgilBridge.parse(
            TestSupport.bridgeEnvelope(["type": "agil:ready"], nonce: nonce),
            nonce: nonce
        ))
    }

    func testNonceEnvelopePreservesChatEvents() throws {
        let nonce = AgilBridge.makeNonce()
        XCTAssertEqual(nonce.count, 64)
        let envelope = TestSupport.bridgeEnvelope([
            "type": "agil:chat",
            "message": ["text": "hello", "from": ["id": "p1", "name": "Alice"]]
        ], nonce: nonce)
        let event = try XCTUnwrap(AgilBridge.parse(envelope, nonce: nonce))
        guard case .chat(let message) = event else {
            return XCTFail("Expected chat")
        }
        XCTAssertEqual(message.participantName, "Alice")
    }

    func testCommandEncoding() throws {
        let action = try AgilBridge.encode(.action(.toggleMic))
        XCTAssertTrue(action.contains(#""type":"agil:action""#))
        XCTAssertTrue(action.contains(#""action":"toggle-mic""#))

        let pip = try AgilBridge.encode(.action(.pip))
        XCTAssertTrue(pip.contains(#""action":"pip""#))
        let newtab = try AgilBridge.encode(.action(.newtab))
        XCTAssertTrue(newtab.contains(#""action":"newtab""#))

        let theme = try AgilBridge.encode(.theme(.dark))
        XCTAssertTrue(theme.contains(#""type":"agil:scheme""#))
        XCTAssertTrue(theme.contains(#""scheme":"dark""#))

        let chat = try AgilBridge.encode(.sendChat("hello"))
        XCTAssertTrue(chat.contains(#""type":"agil:chat-send""#))
        XCTAssertTrue(chat.contains(#""text":"hello""#))

        let patch = try AgilBridge.encode(.themePatch(["scheme": .string("dark")]))
        XCTAssertTrue(patch.contains(#""type":"agil:theme""#))
        XCTAssertTrue(patch.contains(#""scheme":"dark""#))
    }

    func testInvalidCommands() {
        XCTAssertThrowsError(try AgilBridge.encode(.sendChat("   "))) { error in
            XCTAssertEqual(error as? AgilBridgeError, .chatMessageEmpty)
        }
        XCTAssertThrowsError(
            try AgilBridge.encode(.sendChat(String(repeating: "a", count: 4_001)))
        ) { error in
            XCTAssertEqual(
                error as? AgilBridgeError,
                .chatMessageTooLong(limit: AgilBridge.maxChatCharacters)
            )
        }
        XCTAssertThrowsError(try AgilBridge.encode(.themePatch([:]))) { error in
            XCTAssertEqual(error as? AgilBridgeError, .themePatchEmpty)
        }
    }

    func testHostMessageScriptUsesExactOriginAndNoWildcard() throws {
        let script = try AgilBridge.hostMessageScript(.action(.leave))
        XCTAssertTrue(script.contains("window.__agilIOSPostToPage"))
        XCTAssertTrue(script.contains("window.location.origin"))
        XCTAssertFalse(script.contains(#""*""#))
    }

    func testHostMessageScriptEscapesScriptMarkers() throws {
        let script = try AgilBridge.hostMessageScript(
            .sendChat("</script><script>alert(1)</script>")
        )
        XCTAssertFalse(script.contains("</script>"))
        XCTAssertFalse(script.contains("<script>"))
        XCTAssertFalse(script.contains("<"))
        XCTAssertTrue(script.contains(#"\u003c"#))
        XCTAssertTrue(script.contains(#"\u003e"#))
    }

    func testShimScriptIsOriginGuardedAndUsesAgilBridge() {
        let nonce = "fixed-test-nonce"
        let script = AgilBridge.shimScript(
            widgetOrigin: "https://calls.example.com",
            nonce: nonce
        )
        XCTAssertTrue(script.contains(#""https://calls.example.com""#))
        XCTAssertTrue(script.contains("AgilBridge"))
        XCTAssertTrue(script.contains("messageHandlers"))
        XCTAssertTrue(script.contains("__agilIOSPostToPage"))
        XCTAssertTrue(script.contains(#""fixed-test-nonce""#))
        XCTAssertTrue(script.contains("__agilBridgeNonce"))
        XCTAssertTrue(script.contains("JSON.stringify"))
        XCTAssertFalse(script.contains(#""*""#))
    }

    func testCommandPayloadDropsPrototypeKeys() throws {
        let script = try AgilBridge.encode(.themePatch([
            "__proto__": .object(["polluted": .bool(true)]),
            "scheme": .string("dark")
        ]))
        XCTAssertFalse(script.contains("__proto__"))
        XCTAssertTrue(script.contains(#""scheme":"dark""#))
    }
}
