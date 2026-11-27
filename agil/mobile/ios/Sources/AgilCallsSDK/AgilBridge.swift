import Foundation

// MARK: - Public message types

/// Capabilities reported by the widget in `agil:ready`.
public struct AgilCapabilities: Equatable, Sendable {
    public let media: Bool
    public let blur: Bool
    public let screenShare: Bool
    public let captions: Bool
    public let recording: Bool

    public init(
        media: Bool = false,
        blur: Bool = false,
        screenShare: Bool = false,
        captions: Bool = false,
        recording: Bool = false
    ) {
        self.media = media
        self.blur = blur
        self.screenShare = screenShare
        self.captions = captions
        self.recording = recording
    }
}

/// Payload of the `agil:ready` handshake.
public struct AgilReadyInfo: Equatable, Sendable {
    public let capabilities: AgilCapabilities
    public let room: String?
    public let server: String?

    public init(capabilities: AgilCapabilities, room: String? = nil, server: String? = nil) {
        self.capabilities = capabilities
        self.room = room
        self.server = server
    }
}

/// Chat message emitted by the widget (`agil:chat`).
public struct AgilChatMessage: Equatable, Sendable {
    public let text: String
    public let id: String?
    public let participantId: String?
    public let participantName: String?
    public let timestamp: Date?
    public let raw: AgilJSONValue?

    public init(
        text: String,
        id: String? = nil,
        participantId: String? = nil,
        participantName: String? = nil,
        timestamp: Date? = nil,
        raw: AgilJSONValue? = nil
    ) {
        self.text = text
        self.id = id
        self.participantId = participantId
        self.participantName = participantName
        self.timestamp = timestamp
        self.raw = raw
    }
}

/// Snapshot periodically posted by the widget (`agil:state`).
public struct AgilCallSnapshot: Equatable, Sendable {
    public let phase: String?
    public let participants: Int?
    public let participantIds: [String]
    /// True when this snapshot carries the widget's `participantIds` (an empty
    /// array is a valid snapshot for an empty room; absent means count-only).
    /// Compact states always report false because they drop the id list.
    public let hasParticipantIds: Bool
    public let qualityTier: String?
    public let qualityScore: Double?
    public let connectionState: String?
    public let recording: Bool?
    public let minimized: Bool?
    public let chatMode: String?
    public let fullscreen: Bool?
    public let layoutMode: String?
    public let microphoneEnabled: Bool?
    public let cameraEnabled: Bool?
    public let screenSharing: Bool?
    public let blurMode: String?
    public let panel: String?
    /// Authoritative count from the large-room digest, when this compact state has one.
    public let participantCount: Int?
    /// Monotonic revision of the participant digest, when this compact state has one.
    public let participantRevision: Int?
    public let raw: AgilJSONValue

    public init(
        phase: String? = nil,
        participants: Int? = nil,
        participantIds: [String] = [],
        qualityTier: String? = nil,
        qualityScore: Double? = nil,
        connectionState: String? = nil,
        recording: Bool? = nil,
        minimized: Bool? = nil,
        chatMode: String? = nil,
        fullscreen: Bool? = nil,
        layoutMode: String? = nil,
        microphoneEnabled: Bool? = nil,
        cameraEnabled: Bool? = nil,
        screenSharing: Bool? = nil,
        blurMode: String? = nil,
        panel: String? = nil,
        participantCount: Int? = nil,
        participantRevision: Int? = nil,
        hasParticipantIds: Bool = false,
        raw: AgilJSONValue = .object([:])
    ) {
        self.phase = phase
        self.participants = participants
        self.participantIds = participantIds
        self.hasParticipantIds = hasParticipantIds
        self.qualityTier = qualityTier
        self.qualityScore = qualityScore
        self.connectionState = connectionState
        self.recording = recording
        self.minimized = minimized
        self.chatMode = chatMode
        self.fullscreen = fullscreen
        self.layoutMode = layoutMode
        self.microphoneEnabled = microphoneEnabled
        self.cameraEnabled = cameraEnabled
        self.screenSharing = screenSharing
        self.blurMode = blurMode
        self.panel = panel
        self.participantCount = participantCount
        self.participantRevision = participantRevision
        self.raw = raw
    }
}

/// Stable failure codes exposed by the SDK.
public enum AgilCallFailureCode: String, Equatable, Sendable {
    case invalidConfiguration = "invalid-config"
    case loadFailed = "load-failed"
    case navigationBlocked = "navigation-blocked"
    case permissionDenied = "permission-denied"
    case bridgeTimeout = "bridge-timeout"
    case bridgeError = "bridge-error"
    case renderProcessGone = "render-process-gone"
    case widgetError = "widget-error"
}

/// Token-free failure surfaced to the host.
public struct AgilCallFailure: Error, Equatable, LocalizedError, Sendable {
    public let code: AgilCallFailureCode
    public let message: String
    /// Original widget error code (`mount_failed`, `bad_request`, ...), when the
    /// widget reported one.
    public let widgetCode: String?
    public let fatal: Bool

    public init(
        code: AgilCallFailureCode,
        message: String,
        widgetCode: String? = nil,
        fatal: Bool = false
    ) {
        self.code = code
        self.message = message
        self.widgetCode = widgetCode
        self.fatal = fatal
    }

    public var errorDescription: String? {
        let redacted = AgilRedaction.redactTokenText(message)
        return "\(code.rawValue): \(redacted)"
    }
}

/// Events emitted by the `AgilCallView`.
public enum AgilCallEvent: Equatable, Sendable {
    case ready(AgilReadyInfo)
    case joined(AgilJSONValue?)
    case left(AgilJSONValue?)
    case chat(AgilChatMessage)
    case error(AgilCallFailure)
    case state(AgilCallSnapshot)
    /// Compact participant snapshot/delta (Stage 3b); replaces the 200-id array.
    case participants(AgilParticipantUpdate)
    /// Deduplicated connection/reconnect transition.
    case connection(AgilConnectionUpdate)
    case minimized(Bool)
    case fullscreen(Bool)
    /// Any other widget event (`participant-joined`, `quality-changed`, ...).
    case event(name: String, payload: AgilJSONValue?)

    public var name: String {
        switch self {
        case .ready:
            return "ready"
        case .joined:
            return "joined"
        case .left:
            return "left"
        case .chat:
            return "chat"
        case .error:
            return "error"
        case .state:
            return "state"
        case .participants:
            return "participants"
        case .connection:
            return "connection"
        case .minimized:
            return "minimized"
        case .fullscreen:
            return "fullscreen"
        case .event(let name, _):
            return name
        }
    }
}

/// Actions understood by the hosted widget's `agil:action` handler.
///
/// `join` is kept for forward compatibility with `agil/websdk/embed`'s action
/// list, but the current hosted `/embed.html` answers it with `action-denied`:
/// the host joins by loading the page with `room`/`token`, and the widget
/// renders its own join screen.
public enum AgilCallAction: String, CaseIterable, Equatable, Sendable {
    case join
    case leave
    case toggleMic = "toggle-mic"
    case toggleCamera = "toggle-camera"
    case toggleChat = "toggle-chat"
    case shareScreen = "share-screen"
    case blurOn = "blur-on"
    case blurOff = "blur-off"
    case minimize
    case restore
    case pip
    case fullscreen
    case newtab
}

/// Commands the host can send into the WebView.
public enum AgilCallCommand: Equatable, Sendable {
    case action(AgilCallAction)
    case sendChat(String)
    case theme(AgilThemeScheme)
    case themePatch([String: AgilJSONValue])
    case ping
}

/// Invalid command payload or bridge state. Descriptions never contain tokens.
public enum AgilBridgeError: Error, Equatable, LocalizedError, Sendable {
    case notLoaded
    case queueFull
    case chatMessageEmpty
    case chatMessageTooLong(limit: Int)
    case themePatchEmpty
    case messageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The AgilFrame WebView is not loaded"
        case .queueFull:
            return "Too many queued AgilFrame commands"
        case .chatMessageEmpty:
            return "Chat text must not be empty"
        case .chatMessageTooLong(let limit):
            return "Chat text is too long (max \(limit) characters)"
        case .themePatchEmpty:
            return "Theme patch must be a non-empty object"
        case .messageEncodingFailed:
            return "The AgilFrame bridge could not encode the command"
        }
    }
}

// MARK: - Bridge

enum AgilBridgeParseResult: Equatable {
    case event(AgilCallEvent)
    case pong
    case ignored
}

/// Pure, WebKit-free implementation of the `/embed.html` bridge contract.
///
/// Outgoing messages are accepted only for known `agil:*` types; incoming
/// payloads are structurally sanitized (depth/size/key limits, prototype keys
/// dropped) before they become public Swift values. Nothing here logs.
enum AgilBridge {
    /// JavaScript channel name (`window.AgilBridge.postMessage` and
    /// `webkit.messageHandlers.AgilBridge`).
    static let bridgeName = "AgilBridge"
    /// Maximum UTF-8 size of a raw bridge message (matches the JS SDK).
    static let maxMessageBytes = 262_144
    /// Host commands buffered before `agil:ready`.
    static let maxQueuedCommands = 50
    /// Maximum chat text accepted by `agil:chat-send`.
    static let maxChatCharacters = 4_000

    private static let widgetMessageTypes: Set<String> = [
        "agil:ready",
        "agil:event",
        "agil:chat",
        "agil:state",
        "agil:resize",
        "agil:minimized",
        "agil:fullscreen",
        "agil:pong"
    ]
    private static let eventNamePattern = "^[a-z][a-z0-9-]{0,63}$"
    private static let widgetCodePattern = "^[A-Za-z0-9._-]{1,64}$"
    private static let themeLimits = AgilJSONSanitizer.Limits(
        maxDepth: 12,
        maxArray: 500,
        maxKeys: 500,
        maxString: 8_192
    )

    /// Parser used by the view and unit tests. Returns `nil` for `agil:pong`
    /// and for malformed/unknown messages.
    static func parse(_ payload: Any) -> AgilCallEvent? {
        if case .event(let event) = parseMessage(payload) {
            return event
        }
        return nil
    }

    /// Nonce-enforcing variant used by tests and the view.
    static func parse(_ payload: Any, nonce: String) -> AgilCallEvent? {
        if case .event(let event) = parseMessage(payload, nonce: nonce) {
            return event
        }
        return nil
    }

    static func parseMessage(_ payload: Any) -> AgilBridgeParseResult {
        guard let object = dictionary(from: payload),
              let type = object["type"] as? String,
              type.count <= 64,
              widgetMessageTypes.contains(type) else {
            return .ignored
        }

        switch type {
        case "agil:pong":
            return .pong
        case "agil:ready":
            return .event(.ready(readyInfo(from: object)))
        case "agil:event":
            return parseEvent(object)
        case "agil:chat":
            return parseChat(object)
        case "agil:state":
            return parseState(object)
        case "agil:minimized":
            return .event(.minimized(boolean(object["minimized"]) ?? false))
        case "agil:fullscreen":
            return .event(.fullscreen(boolean(object["fullscreen"]) ?? false))
        default:
            // `agil:resize` is a layout hint for iframe hosts and carries no
            // event for native callers.
            return .ignored
        }
    }

    /// Secure entry point used by the view: unwraps the shim's per-load nonce
    /// envelope and rejects anything that was posted to the message handler
    /// directly (for example by an allowlisted SSO page).
    static func parseMessage(_ payload: Any, nonce: String) -> AgilBridgeParseResult {
        guard let message = unwrap(payload, nonce: nonce) else {
            return .ignored
        }
        return parseMessage(message)
    }

    /// Returns the raw widget message inside `{__agilBridgeNonce, message}` or
    /// `nil` when the envelope is missing/too large/has the wrong nonce.
    static func unwrap(_ payload: Any, nonce: String) -> String? {
        guard !nonce.isEmpty,
              let raw = payload as? String,
              // JSON string escaping can roughly double the inner message size.
              raw.utf8.count <= maxMessageBytes * 2 + 4_096,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let envelope = object as? [String: Any],
              let value = envelope["__agilBridgeNonce"] as? String,
              nonceEquals(value, nonce),
              let message = envelope["message"] as? String else {
            return nil
        }
        return message
    }

    /// Constant-time comparison for the per-load nonce.
    private static func nonceEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count, !left.isEmpty else {
            return false
        }
        var difference: UInt8 = 0
        for index in 0..<left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: Incoming payloads

    private static func readyInfo(from object: [String: Any]) -> AgilReadyInfo {
        let sanitizedCapabilities = AgilJSONSanitizer.sanitize(
            object["capabilities"],
            limits: AgilJSONSanitizer.Limits(maxDepth: 2, maxArray: 8, maxKeys: 16, maxString: 256)
        )
        var capabilities = AgilCapabilities()
        if let value = sanitizedCapabilities, case .object(let fields) = value {
            capabilities = AgilCapabilities(
                media: fields["media"]?.boolValue ?? false,
                blur: fields["blur"]?.boolValue ?? false,
                screenShare: fields["screenShare"]?.boolValue ?? false,
                captions: fields["captions"]?.boolValue ?? false,
                recording: fields["recording"]?.boolValue ?? false
            )
        }
        return AgilReadyInfo(
            capabilities: capabilities,
            room: text(object["room"], max: 200),
            server: text(object["server"], max: 2_048)
        )
    }

    private static func parseEvent(_ object: [String: Any]) -> AgilBridgeParseResult {
        guard let name = eventName(object["event"]) else {
            return .ignored
        }
        let payload = AgilJSONSanitizer.sanitize(object["payload"])
        switch name {
        case "joined":
            return .event(.joined(payload))
        case "left":
            return .event(.left(payload))
        case "error":
            return .event(.error(widgetFailure(from: payload)))
        default:
            return .event(.event(name: name, payload: payload))
        }
    }

    private static func widgetFailure(from payload: AgilJSONValue?) -> AgilCallFailure {
        let fields = payload?.objectValue ?? [:]
        let widgetCode = fields["code"]?.stringValue.flatMap { value -> String? in
            guard value.count <= 64,
                  value.range(of: widgetCodePattern, options: .regularExpression) != nil else {
                return nil
            }
            return value
        }
        let message = messageText(
            fields["message"]?.stringValue,
            fallback: "The AgilFrame widget reported an error"
        )
        return AgilCallFailure(
            code: .widgetError,
            message: message,
            widgetCode: widgetCode,
            fatal: fields["fatal"]?.boolValue ?? false
        )
    }

    private static func parseChat(_ object: [String: Any]) -> AgilBridgeParseResult {
        if let rawText = object["message"] as? String {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .ignored
            }
            return .event(.chat(AgilChatMessage(text: cap(trimmed, max: maxChatCharacters))))
        }
        guard let sanitized = AgilJSONSanitizer.sanitize(object["message"]),
              case .object(let fields) = sanitized,
              let rawText = fields["text"]?.stringValue else {
            return .ignored
        }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .ignored
        }
        // `embed.html` forwards the raw `ChatMessage` from the protocol, whose
        // sender is `from: { id, name, role }`. Hosts still get the flat
        // `participantId`/`participantName` convenience fields, and `raw`
        // keeps the full original object.
        let from = fields["from"]?.objectValue
        func participantId() -> String? {
            if let flat = fields["participantId"]?.stringValue,
               let value = text(flat, max: 200) {
                return value
            }
            return from?["id"]?.stringValue.flatMap { text($0, max: 200) }
        }
        func participantName() -> String? {
            if let flat = fields["participantName"]?.stringValue,
               let value = text(flat, max: 200) {
                return value
            }
            return from?["name"]?.stringValue.flatMap { text($0, max: 200) }
        }
        return .event(.chat(AgilChatMessage(
            text: cap(trimmed, max: maxChatCharacters),
            id: fields["id"]?.stringValue.flatMap { text($0, max: 200) },
            participantId: participantId(),
            participantName: participantName(),
            timestamp: timestamp(fields["ts"]),
            raw: sanitized
        )))
    }

    private static func parseState(_ object: [String: Any]) -> AgilBridgeParseResult {
        // `participantIds` may hold up to 200 entries; the default sanitizer cap
        // is 100, which would silently drop half a large room. Allow the profile
        // cap plus headroom (the view's digest still enforces `maxParticipants`).
        guard let sanitized = AgilJSONSanitizer.sanitize(
            object["state"],
            limits: AgilJSONSanitizer.Limits(maxArray: 500)
        ),
              case .object(let fields) = sanitized else {
            return .ignored
        }
        let quality = fields["quality"]?.objectValue
        let settings = fields["settings"]?.objectValue
        let participantIds: [String] = (fields["participantIds"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
        let hasParticipantIds = fields["participantIds"]?.arrayValue != nil
        return .event(.state(AgilCallSnapshot(
            phase: fields["phase"]?.stringValue.flatMap { text($0, max: 64) },
            participants: fields["participants"]?.intValue.flatMap { value -> Int? in
                guard (0...10_000).contains(value) else {
                    return nil
                }
                return value
            },
            participantIds: participantIds.map { cap($0, max: 200) },
            qualityTier: quality?["tier"]?.stringValue.flatMap { text($0, max: 40) },
            qualityScore: quality?["score"]?.doubleValue,
            connectionState: fields["connectionState"]?.stringValue.flatMap { text($0, max: 40) },
            recording: fields["recording"]?.boolValue,
            minimized: fields["minimized"]?.boolValue,
            chatMode: fields["chatMode"]?.stringValue.flatMap { text($0, max: 40) },
            fullscreen: fields["fullscreen"]?.boolValue,
            layoutMode: fields["layoutMode"]?.stringValue.flatMap { text($0, max: 40) },
            microphoneEnabled: settings?["mic"]?.boolValue,
            cameraEnabled: settings?["camera"]?.boolValue,
            screenSharing: settings?["screen"]?.boolValue,
            blurMode: settings?["blur"]?.stringValue.flatMap { text($0, max: 40) },
            panel: settings?["panel"]?.stringValue.flatMap { text($0, max: 40) },
            hasParticipantIds: hasParticipantIds,
            raw: sanitized
        )))
    }

    // MARK: Commands

    static func commandObject(_ command: AgilCallCommand) throws -> [String: Any] {
        switch command {
        case .action(let action):
            return ["type": "agil:action", "action": action.rawValue]
        case .sendChat(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AgilBridgeError.chatMessageEmpty
            }
            guard text.count <= maxChatCharacters else {
                throw AgilBridgeError.chatMessageTooLong(limit: maxChatCharacters)
            }
            return ["type": "agil:chat-send", "text": text]
        case .theme(let scheme):
            return ["type": "agil:scheme", "scheme": scheme.rawValue]
        case .themePatch(let patch):
            var raw: [String: Any] = [:]
            for (key, value) in patch {
                raw[key] = value.jsonObject
            }
            guard let sanitized = AgilJSONSanitizer.sanitize(raw, limits: themeLimits),
                  case .object(let fields) = sanitized,
                  !fields.isEmpty else {
                throw AgilBridgeError.themePatchEmpty
            }
            var theme: [String: Any] = [:]
            for (key, value) in fields {
                theme[key] = value.jsonObject
            }
            return ["type": "agil:theme", "theme": theme]
        case .ping:
            return ["type": "agil:ping"]
        }
    }

    /// Encodes a command as a JavaScript-safe JSON object literal.
    static func encode(_ command: AgilCallCommand) throws -> String {
        let object = try commandObject(command)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw AgilBridgeError.messageEncodingFailed
        }
        return escapeForJavaScript(json)
    }

    /// Script that delivers a command through the shim's saved original
    /// `postMessage`, with the page's exact origin (never `"*"`).
    static func hostMessageScript(_ command: AgilCallCommand) throws -> String {
        let json = try encode(command)
        return "(function(){try{var p=window.__agilIOSPostToPage||window.postMessage;"
            + "if(typeof p!==\"function\"){return;}"
            + "p.call(window,\(json),window.location.origin);}catch(e){}})();true;"
    }

    /// Per-load random secret embedded only in the shim closure. A page that
    /// calls `webkit.messageHandlers.AgilBridge.postMessage(...)` directly
    /// (including an allowlisted SSO page) cannot produce a valid envelope.
    static func makeNonce() -> String {
        let raw = UUID().uuidString + UUID().uuidString
        return raw.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Shim injected at `.atDocumentStart`.
    ///
    /// The hosted page calls `window.parent.postMessage(...)`; in a top-level
    /// WebView `parent === window`, so the SDK installs `window.AgilBridge`
    /// (matching the documented bridge name) and forwards every outgoing
    /// message to `webkit.messageHandlers.AgilBridge`, while keeping the page's
    /// own `message` listener alive. Idempotent and origin-guarded.
    ///
    /// Every forwarded message is wrapped in `{__agilBridgeNonce, message}` so
    /// the native side can reject direct handler calls from any other page.
    static func shimScript(widgetOrigin: String, nonce: String) -> String {
        let origin = jsStringLiteral(widgetOrigin)
        let nonceLiteral = jsStringLiteral(nonce)
        return """
        (function(){try{
        var w=window;
        if(!w||w.__agilIOSBridgeInstalled){return;}
        if(w.location.origin!==\(origin)){return;}
        var nonce=\(nonceLiteral);
        if(typeof nonce!=="string"||!nonce){return;}
        var handler=null;
        try{var handlers=w.webkit&&w.webkit.messageHandlers;handler=handlers&&handlers.AgilBridge;}catch(e){}
        if(!handler||typeof handler.postMessage!=="function"){return;}
        var send=function(message){
        try{
        var text=typeof message==="string"?message:JSON.stringify(message);
        handler.postMessage(JSON.stringify({__agilBridgeNonce:nonce,message:text}));
        }catch(e){}
        };
        w.__agilIOSChannel={postMessage:send};
        if(!w.AgilBridge||typeof w.AgilBridge.postMessage!=="function"){w.AgilBridge={postMessage:send};}
        var channel=w.__agilIOSChannel;
        var original=w.parent.postMessage;
        if(typeof original!=="function"){return;}
        var forward=function(message){
        try{channel.postMessage(typeof message==="string"?message:JSON.stringify(message));}catch(e){}
        try{return original.call(w.parent,message,w.location.origin);}catch(e){}
        };
        var installed=false;
        try{w.parent.postMessage=forward;installed=w.parent.postMessage===forward;}catch(e){}
        if(!installed){try{Object.defineProperty(w.parent,"postMessage",{value:forward,writable:true,configurable:true});installed=w.parent.postMessage===forward;}catch(e2){}}
        if(installed){w.__agilIOSPostToPage=original;w.__agilIOSBridgeInstalled=true;}
        }catch(e){}})();true;
        """
    }

    // MARK: Helpers

    private static func dictionary(from payload: Any) -> [String: Any]? {
        if let raw = payload as? String {
            guard !raw.isEmpty,
                  raw.utf8.count <= maxMessageBytes,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
                return nil
            }
            return object as? [String: Any]
        }
        if let dictionary = payload as? [String: Any] {
            return dictionary
        }
        if let dictionary = payload as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else {
                    continue
                }
                result[key] = value
            }
            return result
        }
        return nil
    }

    private static func eventName(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.count <= 64,
              value.range(of: eventNamePattern, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func text(_ value: Any?, max: Int) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AgilValidation.hasControlCharacters(trimmed) else {
            return nil
        }
        return cap(trimmed, max: max)
    }

    private static func messageText(_ value: String?, fallback: String) -> String {
        guard let value = value else {
            return fallback
        }
        let redacted = AgilRedaction.redactTokenText(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else {
            return fallback
        }
        return cap(redacted, max: 500)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let sanitized = AgilJSONSanitizer.sanitize(value),
              case .bool(let value) = sanitized else {
            return nil
        }
        return value
    }

    private static func timestamp(_ value: AgilJSONValue?) -> Date? {
        guard let milliseconds = value?.doubleValue,
              milliseconds.isFinite,
              milliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func cap(_ value: String, max: Int) -> String {
        guard value.count > max else {
            return value
        }
        return String(value.prefix(max))
    }

    private static func escapeForJavaScript(_ json: String) -> String {
        return json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"\""
        }
        // Origins cannot contain backslashes, so `\/` here is only the optional
        // JSON slash escape (Linux emits it, Apple does not); normalizing keeps
        // the exact origin guard identical on every platform.
        let literal = String(json.dropFirst().dropLast())
            .replacingOccurrences(of: "\\/", with: "/")
        return escapeForJavaScript(literal)
    }
}
