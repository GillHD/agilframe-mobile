import Foundation

// MARK: - Join result types

/// Room metadata returned by `POST /v1/rooms/:id/join`.
public struct AgilRoomInfo: Equatable, Sendable {
    public let id: String
    public let tenantId: String?
    public let name: String?
    public let locked: Bool?
    public let createdAt: Date?

    public init(
        id: String,
        tenantId: String? = nil,
        name: String? = nil,
        locked: Bool? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.tenantId = tenantId
        self.name = name
        self.locked = locked
        self.createdAt = createdAt
    }

    init?(json: [String: AgilJSONValue]) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else {
            return nil
        }
        self.init(
            id: id,
            tenantId: json["tenantId"]?.stringValue,
            name: json["name"]?.stringValue,
            locked: json["locked"]?.boolValue,
            createdAt: AgilDate.fromMilliseconds(json["createdAt"])
        )
    }
}

/// Participant identity returned by `POST /v1/rooms/:id/join`.
public struct AgilParticipant: Equatable, Sendable {
    public let id: String
    public let name: String?
    public let role: String?

    public init(id: String, name: String? = nil, role: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
    }

    init?(json: [String: AgilJSONValue]) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else {
            return nil
        }
        self.init(
            id: id,
            name: json["name"]?.stringValue,
            role: json["role"]?.stringValue
        )
    }
}

/// Optional SFU media grant exposed by the join response.
///
/// The iOS WebView widget negotiates media itself; this value is informational
/// for hosts that run their own SFU integration. ``token`` is sensitive.
public struct AgilMediaGrant: Equatable, Sendable {
    public let mode: String
    public let url: URL?
    public let token: String
    public let room: String?
    public let canPublish: Bool
    public let expiresAt: Date?

    public init(
        mode: String,
        url: URL? = nil,
        token: String,
        room: String? = nil,
        canPublish: Bool = false,
        expiresAt: Date? = nil
    ) {
        self.mode = mode
        self.url = url
        self.token = token
        self.room = room
        self.canPublish = canPublish
        self.expiresAt = expiresAt
    }

    init?(json: [String: AgilJSONValue]) {
        guard let token = json["token"]?.stringValue, !token.isEmpty else {
            return nil
        }
        self.init(
            mode: json["mode"]?.stringValue ?? "unknown",
            url: json["url"]?.stringValue.flatMap { URL(string: $0) },
            token: token,
            room: json["room"]?.stringValue,
            canPublish: json["canPublish"]?.boolValue ?? false,
            expiresAt: AgilDate.fromMilliseconds(json["expiresAt"])
        )
    }
}

/// Successful join payload: join token, room/participant, effective
/// permissions, optional SFU media grant and the tenant config snapshot.
public struct AgilJoinResult: Equatable, Sendable {
    public let joinToken: String
    public let expiresAt: Date?
    public let room: AgilRoomInfo
    public let participant: AgilParticipant
    public let permissions: [String]
    public let media: AgilMediaGrant?
    public let passwordAccepted: Bool
    public let config: AgilJSONValue?

    public init(
        joinToken: String,
        expiresAt: Date? = nil,
        room: AgilRoomInfo,
        participant: AgilParticipant,
        permissions: [String] = [],
        media: AgilMediaGrant? = nil,
        passwordAccepted: Bool = false,
        config: AgilJSONValue? = nil
    ) {
        self.joinToken = joinToken
        self.expiresAt = expiresAt
        self.room = room
        self.participant = participant
        self.permissions = permissions
        self.media = media
        self.passwordAccepted = passwordAccepted
        self.config = config
    }
}

/// Waiting-room ticket returned by `POST /v1/rooms/:id/join` with HTTP 202 when
/// the tenant enables a lobby.
public struct AgilLobbyTicket: Equatable, Sendable {
    public let requestId: String
    public let roomId: String?
    public let status: String
    public let expiresAt: Date?
    /// Server-recommended poll interval in seconds.
    public let pollAfter: TimeInterval?

    public init(
        requestId: String,
        roomId: String? = nil,
        status: String = "pending",
        expiresAt: Date? = nil,
        pollAfter: TimeInterval? = nil
    ) {
        self.requestId = requestId
        self.roomId = roomId
        self.status = status
        self.expiresAt = expiresAt
        self.pollAfter = pollAfter
    }
}

/// Result of ``AgilClient/join(roomId:name:password:participantId:locale:identityToken:)``.
public enum AgilJoinOutcome: Equatable, Sendable {
    case joined(AgilJoinResult)
    case waitingRoom(AgilLobbyTicket)
}

// MARK: - Client errors

/// Coarse transport failure classification (no URLs or server text).
public enum AgilTransportFailure: String, Equatable, Sendable {
    case offline
    case timedOut
    case cannotConnect
    case dns
    case tls
    case other
}

/// Typed, token-free errors from the REST client.
///
/// Known server codes are mapped to dedicated cases so hosts can localize them;
/// unknown responses degrade to ``server(status:code:)`` without echoing the
/// server message.
public enum AgilClientError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case invalidResponse
    case invalidRequestBody
    case notFound
    case roomLocked
    case roomFull
    case passwordRequired
    case passwordInvalid
    case identityRequired
    case identityInvalid
    case identityNotVerified
    case identityNotConfigured
    case geoBlocked
    case forbidden
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case validationFailed(message: String)
    case serviceUnavailable
    case server(status: Int, code: String?)
    case transport(AgilTransportFailure)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The join request was cancelled"
        case .invalidResponse:
            return "AgilFrame returned a malformed join response"
        case .invalidRequestBody:
            return "The join request could not be encoded"
        case .notFound:
            return "Room not found"
        case .roomLocked:
            return "The room is locked"
        case .roomFull:
            return "The room is full"
        case .passwordRequired:
            return "A room password is required"
        case .passwordInvalid:
            return "The room password is invalid"
        case .identityRequired:
            return "Corporate identity verification is required"
        case .identityInvalid:
            return "The corporate identity token was rejected"
        case .identityNotVerified:
            return "The corporate identity is not verified"
        case .identityNotConfigured:
            return "Corporate identity (OIDC) is not configured for this tenant"
        case .geoBlocked:
            return "Joining is not allowed from this country"
        case .forbidden:
            return "Joining this room is forbidden"
        case .unauthorized:
            return "The join request was not authorized"
        case .rateLimited(let retryAfter):
            if let retryAfter = retryAfter {
                return "Too many join attempts; retry after \(Int(retryAfter.rounded(.up))) s"
            }
            return "Too many join attempts; try again later"
        case .quotaExceeded:
            return "The tenant quota is exhausted"
        case .validationFailed(let message):
            return AgilRedaction.redactTokenText(message)
        case .serviceUnavailable:
            return "AgilFrame is temporarily unavailable"
        case .server(let status, let code):
            if let code = code {
                return "AgilFrame returned HTTP \(status) (\(code))"
            }
            return "AgilFrame returned HTTP \(status)"
        case .transport(let failure):
            switch failure {
            case .offline:
                return "No network connection"
            case .timedOut:
                return "The join request timed out"
            case .cannotConnect:
                return "Could not connect to AgilFrame"
            case .dns:
                return "Could not resolve the AgilFrame host"
            case .tls:
                return "The TLS connection to AgilFrame failed"
            case .other:
                return "The join request failed"
            }
        }
    }
}

// MARK: - Client

/// Async/await client for the public join endpoint.
///
/// The client intentionally implements only `POST /v1/rooms/:id/join`: it is the
/// one endpoint an app needs to obtain a short-lived join token
/// (`docs/api.md` §4). Admin endpoints and tenant API keys belong on a backend,
/// never in an app bundle.
///
/// ```swift
/// let client = try AgilClient(serverURL: URL(string: "https://calls.example.com")!)
/// switch try await client.join(roomId: "demo", name: "Alice") {
/// case .joined(let result):
///     let configuration = try AgilCallConfiguration(
///         serverURL: client.serverURL,
///         tenantId: result.room.tenantId ?? "demo",
///         roomId: result.room.id,
///         joinToken: result.joinToken
///     )
/// case .waitingRoom:
///     // Tenant lobby: poll the public lobby status endpoint on your backend.
///     break
/// }
/// ```
public struct AgilClient {
    public let serverURL: URL
    /// Optional `x-api-key`. Not required by the public join endpoint; present
    /// for deployments that front it with an API-key gateway.
    public let apiKey: String?

    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        serverURL: URL,
        apiKey: String? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        allowsInsecureHTTP: Bool = false
    ) throws {
        let server = try AgilValidation.serverURL(
            serverURL,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
        self.serverURL = server.url
        self.apiKey = try AgilValidation.apiKey(apiKey)
        self.session = session
        self.timeout = max(1, timeout)
    }

    public init(
        serverURL: String,
        apiKey: String? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        allowsInsecureHTTP: Bool = false
    ) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !AgilValidation.hasControlCharacters(trimmed),
              let url = URL(string: trimmed) else {
            throw AgilConfigurationError(field: .serverURL, reason: .notAnAbsoluteURL)
        }
        try self.init(
            serverURL: url,
            apiKey: apiKey,
            session: session,
            timeout: timeout,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
    }

    /// Joins a room and returns either a join token or a lobby ticket.
    ///
    /// - Throws: ``AgilConfigurationError`` for invalid input and
    /// ``AgilClientError`` for network/HTTP failures.
    public func join(
        roomId: String,
        name: String? = nil,
        password: String? = nil,
        participantId: String? = nil,
        locale: String? = nil,
        identityToken: String? = nil
    ) async throws -> AgilJoinOutcome {
        let request = try makeJoinRequest(
            roomId: roomId,
            name: name,
            password: password,
            participantId: participantId,
            locale: locale,
            identityToken: identityToken
        )
        let (data, response) = try await perform(request)
        return try AgilJoinResponseParser.decode(data: data, response: response)
    }

    // MARK: Request

    /// Builds the join request without sending it. Internal so unit tests can
    /// assert headers/body without a live network.
    func makeJoinRequest(
        roomId: String,
        name: String? = nil,
        password: String? = nil,
        participantId: String? = nil,
        locale: String? = nil,
        identityToken: String? = nil
    ) throws -> URLRequest {
        let validatedRoomId = try AgilValidation.roomId(roomId)
        let validatedName = try AgilValidation.participantName(name)
        let validatedPassword = try AgilValidation.password(password)
        let validatedParticipantId = try AgilValidation.participantId(participantId)
        let validatedLocale = try AgilValidation.locale(locale)
        let validatedIdentityToken = try AgilValidation.token(
            identityToken,
            field: .identityToken,
            maxLength: AgilValidation.maxIdentityTokenLength
        )

        var body: [String: Any] = [:]
        if let validatedName = validatedName {
            body["name"] = validatedName
        }
        if let validatedPassword = validatedPassword {
            body["password"] = validatedPassword
        }
        if let validatedParticipantId = validatedParticipantId {
            body["participantId"] = validatedParticipantId
        }
        if let validatedLocale = validatedLocale {
            body["locale"] = validatedLocale
        }
        if let validatedIdentityToken = validatedIdentityToken {
            body["identityToken"] = validatedIdentityToken
        }
        return try buildRequest(roomId: validatedRoomId, body: body)
    }

    private func buildRequest(roomId: String, body: [String: Any]) throws -> URLRequest {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw AgilConfigurationError(field: .serverURL, reason: .invalidValue)
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/v1/rooms/\(roomId)/join"
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw AgilConfigurationError(field: .serverURL, reason: .invalidValue)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw AgilClientError.invalidRequestBody
        }
        return request
    }

    // MARK: Transport

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let state = AgilRequestState()
        let result: (Data, URLResponse) = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        if state.isCancelled || (error as? URLError)?.code == .cancelled {
                            continuation.resume(throwing: AgilClientError.cancelled)
                        } else {
                            continuation.resume(
                                throwing: AgilClientError.transport(
                                    AgilClient.transportFailure(error)
                                )
                            )
                        }
                        return
                    }
                    guard let data = data, let response = response as? HTTPURLResponse else {
                        continuation.resume(throwing: AgilClientError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: (data, response as URLResponse))
                }
                state.attach(task)
                task.resume()
            }
        }, onCancel: {
            state.cancel()
        })
        if state.isCancelled {
            throw AgilClientError.cancelled
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw AgilClientError.invalidResponse
        }
        return (result.0, response)
    }

    private static func transportFailure(_ error: Error) -> AgilTransportFailure {
        guard let urlError = error as? URLError else {
            return .other
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost:
            return .cannotConnect
        case .cannotFindHost, .dnsLookupFailed:
            return .dns
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .tls
        default:
            return .other
        }
    }
}

// MARK: - Response parsing

enum AgilDate {
    static func fromMilliseconds(_ value: AgilJSONValue?) -> Date? {
        guard let milliseconds = value?.doubleValue, milliseconds.isFinite, milliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

enum AgilJoinResponseParser {
    static func decode(data: Data, response: HTTPURLResponse) throws -> AgilJoinOutcome {
        let status = response.statusCode
        let json = parseJSON(data)

        if status == 202 {
            guard let root = json?.objectValue, let ticket = lobbyTicket(from: root) else {
                throw AgilClientError.invalidResponse
            }
            return .waitingRoom(ticket)
        }
        guard (200...299).contains(status) else {
            throw clientError(status: status, json: json, response: response)
        }
        guard let root = json?.objectValue else {
            throw AgilClientError.invalidResponse
        }
        if root["pending"]?.boolValue == true || root["status"]?.stringValue == "pending" {
            guard let ticket = lobbyTicket(from: root) else {
                throw AgilClientError.invalidResponse
            }
            return .waitingRoom(ticket)
        }
        guard let joinToken = root["token"]?.stringValue, !joinToken.isEmpty else {
            throw AgilClientError.invalidResponse
        }
        guard let roomObject = root["room"]?.objectValue,
              let room = AgilRoomInfo(json: roomObject),
              let participantObject = root["participant"]?.objectValue,
              let participant = AgilParticipant(json: participantObject) else {
            throw AgilClientError.invalidResponse
        }
        let permissions = root["permissions"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let media = root["media"]?.objectValue.flatMap { AgilMediaGrant(json: $0) }
        return .joined(AgilJoinResult(
            joinToken: joinToken,
            expiresAt: AgilDate.fromMilliseconds(root["expiresAt"]),
            room: room,
            participant: participant,
            permissions: permissions,
            media: media,
            passwordAccepted: root["passwordAccepted"]?.boolValue ?? false,
            config: root["config"]
        ))
    }

    private static func parseJSON(_ data: Data) -> AgilJSONValue? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return AgilJSONSanitizer.sanitize(object, limits: .response)
    }

    private static func lobbyTicket(from root: [String: AgilJSONValue]) -> AgilLobbyTicket? {
        guard let requestId = root["requestId"]?.stringValue, !requestId.isEmpty else {
            return nil
        }
        return AgilLobbyTicket(
            requestId: requestId,
            roomId: root["roomId"]?.stringValue,
            status: root["status"]?.stringValue ?? "pending",
            expiresAt: AgilDate.fromMilliseconds(root["expiresAt"]),
            pollAfter: root["pollAfterMs"]?.doubleValue.map { $0 / 1_000 }
        )
    }

    private static func clientError(
        status: Int,
        json: AgilJSONValue?,
        response: HTTPURLResponse
    ) -> AgilClientError {
        let errorObject = json?["error"]?.objectValue ?? [:]
        let code = sanitizedCode(errorObject["code"]?.stringValue)
        let retryAfter = retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"))

        switch code {
        case "not_found":
            return .notFound
        case "room_locked":
            return .roomLocked
        case "room_full":
            return .roomFull
        case "password_required":
            return .passwordRequired
        case "password_invalid":
            return .passwordInvalid
        case "identity_required":
            return .identityRequired
        case "invalid_identity_token":
            return .identityInvalid
        case "identity_not_verified":
            return .identityNotVerified
        case "identity_not_configured":
            return .identityNotConfigured
        case "geo_blocked":
            return .geoBlocked
        case "forbidden":
            return .forbidden
        case "unauthorized":
            return .unauthorized
        case "rate_limited":
            return .rateLimited(retryAfter: retryAfter)
        case "quota_exceeded":
            return .quotaExceeded
        case "validation_failed":
            let raw = errorObject["message"]?.stringValue ?? "The join request was rejected"
            let message = capped(AgilRedaction.redactTokenText(raw), max: 500)
            return .validationFailed(message: message)
        default:
            break
        }

        switch status {
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 404:
            return .notFound
        case 423:
            return .roomLocked
        case 409:
            return .roomFull
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 503:
            return .serviceUnavailable
        default:
            return .server(status: status, code: code)
        }
    }

    private static func sanitizedCode(_ value: String?) -> String? {
        guard let value = value?.lowercased(),
              value.count <= 64,
              value.range(of: "^[a-z0-9._-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func retryAfterSeconds(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            guard seconds.isFinite, seconds >= 0 else {
                return nil
            }
            return min(seconds, 86_400)
        }
        // RFC 9110 allows an HTTP-date instead of delta-seconds.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return min(max(0, date.timeIntervalSinceNow), 86_400)
    }

    private static func capped(_ value: String, max: Int) -> String {
        guard value.count > max else {
            return value
        }
        return String(value.prefix(max))
    }
}

// MARK: - Cancellation state

private final class AgilRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func attach(_ task: URLSessionDataTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - Redacted descriptions

extension AgilClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "AgilClient(serverURL: \(AgilRedaction.redactURL(serverURL)), "
            + "apiKey: \(apiKey == nil ? "none" : "redacted"), timeout: \(timeout))"
    }

    public var debugDescription: String {
        return description
    }
}

extension AgilJoinResult: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "AgilJoinResult(room: \(room.id), participant: \(participant.id), "
            + "permissions: \(permissions.count), media: \(media?.mode ?? "none"), "
            + "token: redacted)"
    }

    public var debugDescription: String {
        return description
    }
}

extension AgilMediaGrant: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "AgilMediaGrant(mode: \(mode), room: \(room ?? "none"), "
            + "canPublish: \(canPublish), token: redacted)"
    }

    public var debugDescription: String {
        return description
    }
}
