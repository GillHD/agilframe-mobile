import Foundation
import XCTest
@testable import AgilCallsSDK

final class AgilClientTests: XCTestCase {
    private let server = URL(string: "https://calls.example.com")!

    func testJoinResultParsing() throws {
        let body = TestSupport.jsonData([
            "token": "join.token.value",
            "expiresAt": 1_760_014_400_000,
            "room": [
                "id": "demo",
                "tenantId": "acme",
                "name": "Support",
                "locked": false,
                "createdAt": 1_760_000_000_000
            ],
            "participant": ["id": "p1", "name": "Alice", "role": "guest"],
            "config": ["features": ["chat": true, "screenShare": false]],
            "passwordAccepted": true,
            "permissions": ["chat", "screenShare"],
            "media": [
                "mode": "sfu",
                "url": "wss://sfu.example.com",
                "token": "media-token",
                "room": "acme__demo",
                "canPublish": true,
                "expiresAt": 1_760_014_400_000
            ]
        ])
        let outcome = try AgilJoinResponseParser.decode(
            data: body,
            response: TestSupport.httpResponse(status: 200)
        )
        guard case .joined(let result) = outcome else {
            return XCTFail("Expected joined")
        }
        XCTAssertEqual(result.joinToken, "join.token.value")
        XCTAssertEqual(result.room.id, "demo")
        XCTAssertEqual(result.room.tenantId, "acme")
        XCTAssertEqual(result.room.name, "Support")
        XCTAssertEqual(result.room.locked, false)
        XCTAssertNotNil(result.room.createdAt)
        XCTAssertEqual(result.participant.id, "p1")
        XCTAssertEqual(result.participant.role, "guest")
        XCTAssertEqual(result.permissions, ["chat", "screenShare"])
        XCTAssertEqual(result.passwordAccepted, true)
        XCTAssertEqual(result.media?.mode, "sfu")
        XCTAssertEqual(result.media?.token, "media-token")
        XCTAssertEqual(result.media?.canPublish, true)
        XCTAssertEqual(result.config?["features"]?["chat"]?.boolValue, true)
        XCTAssertNotNil(result.expiresAt)
    }

    func testWaitingRoomTicketParsing() throws {
        let body = TestSupport.jsonData([
            "pending": true,
            "requestId": "r1",
            "roomId": "demo",
            "status": "pending",
            "expiresAt": 1_760_000_000_000,
            "pollAfterMs": 2_000
        ])
        let outcome = try AgilJoinResponseParser.decode(
            data: body,
            response: TestSupport.httpResponse(status: 202)
        )
        guard case .waitingRoom(let ticket) = outcome else {
            return XCTFail("Expected waitingRoom")
        }
        XCTAssertEqual(ticket.requestId, "r1")
        XCTAssertEqual(ticket.roomId, "demo")
        XCTAssertEqual(ticket.status, "pending")
        XCTAssertEqual(ticket.pollAfter, 2.0)
        XCTAssertNotNil(ticket.expiresAt)
    }

    func testKnownErrorCodesAreTyped() throws {
        let cases: [(Int, String, AgilClientError)] = [
            (404, "not_found", .notFound),
            (423, "room_locked", .roomLocked),
            (409, "room_full", .roomFull),
            (400, "password_required", .passwordRequired),
            (401, "password_invalid", .passwordInvalid),
            (401, "identity_required", .identityRequired),
            (401, "invalid_identity_token", .identityInvalid),
            (403, "identity_not_verified", .identityNotVerified),
            (501, "identity_not_configured", .identityNotConfigured),
            (403, "geo_blocked", .geoBlocked),
            (403, "forbidden", .forbidden),
            (401, "unauthorized", .unauthorized),
            (429, "rate_limited", .rateLimited(retryAfter: nil)),
            (429, "quota_exceeded", .quotaExceeded)
        ]
        for (status, code, expected) in cases {
            let body = TestSupport.jsonData(["error": ["code": code, "message": "server text"]])
            XCTAssertThrowsError(
                try AgilJoinResponseParser.decode(
                    data: body,
                    response: TestSupport.httpResponse(status: status)
                )
            ) { error in
                XCTAssertEqual(error as? AgilClientError, expected, "code \(code)")
            }
        }
    }

    func testRateLimitRetryAfterHeader() {
        let body = TestSupport.jsonData([
            "error": ["code": "rate_limited", "message": "slow down"]
        ])
        XCTAssertThrowsError(
            try AgilJoinResponseParser.decode(
                data: body,
                response: TestSupport.httpResponse(
                    status: 429,
                    headers: ["Retry-After": "12"]
                )
            )
        ) { error in
            XCTAssertEqual(error as? AgilClientError, .rateLimited(retryAfter: 12))
        }
    }

    func testRateLimitRetryAfterHTTPDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = Date().addingTimeInterval(60)
        let body = TestSupport.jsonData([
            "error": ["code": "rate_limited", "message": "slow down"]
        ])
        XCTAssertThrowsError(
            try AgilJoinResponseParser.decode(
                data: body,
                response: TestSupport.httpResponse(
                    status: 429,
                    headers: ["Retry-After": formatter.string(from: future)]
                )
            )
        ) { error in
            guard case .rateLimited(let retryAfter)? = error as? AgilClientError,
                  let retryAfter = retryAfter else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertGreaterThan(retryAfter, 30)
            XCTAssertLessThanOrEqual(retryAfter, 60)
        }
    }


    func testValidationMessageIsRedacted() {
        let body = TestSupport.jsonData([
            "error": [
                "code": "validation_failed",
                "message": "bad token=super-secret and identity_token=other-secret"
            ]
        ])
        XCTAssertThrowsError(
            try AgilJoinResponseParser.decode(
                data: body,
                response: TestSupport.httpResponse(status: 400)
            )
        ) { error in
            guard case .validationFailed(let message)? = error as? AgilClientError else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertFalse(message.contains("super-secret"))
            XCTAssertFalse(message.contains("other-secret"))
            XCTAssertTrue(message.contains("redacted"))
        }
    }

    func testUnknownServerErrorOmitsMessage() {
        let body = TestSupport.jsonData([
            "error": ["code": "internal_error", "message": "token=secret internal failure"]
        ])
        XCTAssertThrowsError(
            try AgilJoinResponseParser.decode(
                data: body,
                response: TestSupport.httpResponse(status: 500)
            )
        ) { error in
            guard case .server(let status, let code)? = error as? AgilClientError else {
                return XCTFail("Expected server error, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code, "internal_error")
            XCTAssertFalse((error as? AgilClientError)?.localizedDescription.contains("secret") ?? true)
        }
    }

    func testMalformedSuccessAndErrorBodies() {
        XCTAssertThrowsError(
            try AgilJoinResponseParser.decode(
                data: Data("not json".utf8),
                response: TestSupport.httpResponse(status: 200)
            )
        ) { error in
            XCTAssertEqual(error as? AgilClientError, .invalidResponse)
        }
        let missingToken = TestSupport.jsonData([
            "room": ["id": "demo"],
            "participant": ["id": "p1"]
        ])
        XCTAssertThrowsError(
            try AgilJoinResponseParser.decode(
                data: missingToken,
                response: TestSupport.httpResponse(status: 200)
            )
        ) { error in
            XCTAssertEqual(error as? AgilClientError, .invalidResponse)
        }
    }

    func testClientValidation() {
        TestSupport.assertConfigurationError(.serverURL, .insecureHTTP) {
            _ = try AgilClient(serverURL: URL(string: "http://calls.example.com")!)
        }
        TestSupport.assertConfigurationError(.apiKey, .containsWhitespace) {
            _ = try AgilClient(serverURL: self.server, apiKey: "key with space")
        }
        TestSupport.assertConfigurationError(.apiKey, .containsControlCharacters) {
            _ = try AgilClient(serverURL: self.server, apiKey: "key\ninjection")
        }
    }

    func testJoinInputValidation() async throws {
        let client = try AgilClient(serverURL: server)
        do {
            _ = try await client.join(roomId: "../admin")
            XCTFail("Expected room validation error")
        } catch let error as AgilConfigurationError {
            XCTAssertEqual(error.field, .roomId)
            XCTAssertEqual(error.reason, .invalidValue)
        }
        do {
            _ = try await client.join(roomId: "demo", locale: "de")
            XCTFail("Expected locale validation error")
        } catch let error as AgilConfigurationError {
            XCTAssertEqual(error.field, .locale)
            XCTAssertEqual(error.reason, .invalidValue)
        }
    }

    func testJoinRequestHeadersBodyAndURL() throws {
        let client = try AgilClient(
            serverURL: URL(string: "https://calls.example.com/calls")!,
            apiKey: "api-key"
        )
        let request = try client.makeJoinRequest(
            roomId: "demo",
            name: "  Alice  ",
            participantId: "p1",
            locale: "ru",
            identityToken: "identity.token.value"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://calls.example.com/calls/v1/rooms/demo/join"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertFalse(request.url?.absoluteString.contains("identity.token.value") ?? true)

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["name"] as? String, "Alice")
        XCTAssertEqual(object["participantId"] as? String, "p1")
        XCTAssertEqual(object["locale"] as? String, "ru")
        XCTAssertEqual(object["identityToken"] as? String, "identity.token.value")
    }

    func testJoinRequestUsesSessionAndParsesResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.handler = nil
        }

        let responseBody = TestSupport.jsonData([
            "token": "join.token.value",
            "room": ["id": "demo", "tenantId": "demo"],
            "participant": ["id": "p1", "name": "Alice", "role": "guest"]
        ])
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }

        let client = try AgilClient(
            serverURL: URL(string: "https://calls.example.com/calls")!,
            apiKey: "api-key",
            session: session
        )
        let outcome = try await client.join(
            roomId: "demo",
            name: "  Alice  ",
            participantId: "p1",
            locale: "ru",
            identityToken: "identity.token.value"
        )
        guard case .joined(let result) = outcome else {
            return XCTFail("Expected joined")
        }
        XCTAssertEqual(result.joinToken, "join.token.value")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://calls.example.com/calls/v1/rooms/demo/join"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "api-key")
    }

    func testClientDescriptionRedactsApiKey() throws {
        let client = try AgilClient(serverURL: server, apiKey: "super-secret-key")
        let rendered = String(describing: client)
        XCTAssertFalse(rendered.contains("super-secret-key"))
        XCTAssertTrue(rendered.contains("apiKey: redacted"))
    }

    func testJoinResultDescriptionRedactsToken() {
        let result = AgilJoinResult(
            joinToken: "super-secret-join-token",
            room: AgilRoomInfo(id: "demo"),
            participant: AgilParticipant(id: "p1")
        )
        let rendered = String(describing: result)
        XCTAssertFalse(rendered.contains("super-secret-join-token"))
        XCTAssertTrue(rendered.contains("token: redacted"))
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
