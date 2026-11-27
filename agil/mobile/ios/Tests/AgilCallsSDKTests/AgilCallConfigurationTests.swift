import Foundation
import XCTest
@testable import AgilCallsSDK

final class AgilCallConfigurationTests: XCTestCase {
    private let server = TestSupport.server

    func testValidConfigurationNormalizesValues() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: server,
            tenantId: " acme ",
            roomId: " room-1 ",
            joinToken: "join.token.value",
            participantName: " Alice ",
            theme: .dark,
            language: "en-US",
            relayOnly: true,
            allowedOrigins: ["https://CDN.Example.com:443/"],
            widgetPath: "embed.html",
            identityToken: "identity.token.value"
        )

        XCTAssertEqual(configuration.roomId, "room-1")
        XCTAssertEqual(configuration.tenantId, "acme")
        XCTAssertEqual(configuration.participantName, "Alice")
        XCTAssertEqual(configuration.language, "en")
        XCTAssertEqual(configuration.theme, .dark)
        XCTAssertTrue(configuration.relayOnly)
        XCTAssertEqual(configuration.allowedOrigins, ["https://cdn.example.com"])
        XCTAssertEqual(configuration.widgetOrigin, "https://calls.example.com")
        XCTAssertEqual(configuration.serverURL.absoluteString, "https://calls.example.com")
        XCTAssertEqual(configuration.normalizedServerURL, "https://calls.example.com")
    }

    func testDefaults() throws {
        let configuration = try AgilCallConfiguration(serverURL: server, roomId: "demo")
        XCTAssertEqual(configuration.tenantId, "demo")
        XCTAssertEqual(configuration.widgetPath, "embed.html")
        XCTAssertNil(configuration.joinToken)
        XCTAssertNil(configuration.identityToken)
        XCTAssertNil(configuration.theme)
        XCTAssertFalse(configuration.relayOnly)
        XCTAssertFalse(configuration.allowsInsecureHTTP)
        XCTAssertTrue(configuration.allowedOrigins.isEmpty)
    }

    func testSubpathServerIsPreserved() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: URL(string: "https://calls.example.com/calls/")!,
            roomId: "demo"
        )
        XCTAssertEqual(configuration.serverURL.absoluteString, "https://calls.example.com/calls")
        XCTAssertEqual(configuration.normalizedServerURL, "https://calls.example.com/calls")
        XCTAssertEqual(configuration.widgetOrigin, "https://calls.example.com")
    }

    func testRoomIdValidation() {
        TestSupport.assertConfigurationError(.roomId, .missing) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "   ")
        }
        TestSupport.assertConfigurationError(.roomId, .invalidValue) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "../admin")
        }
        TestSupport.assertConfigurationError(.roomId, .invalidValue) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "room with space")
        }
        TestSupport.assertConfigurationError(.roomId, .tooLong) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: String(repeating: "a", count: 65)
            )
        }
        TestSupport.assertConfigurationError(.roomId, .containsControlCharacters) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo\nroom")
        }
    }

    func testTenantIdValidation() {
        TestSupport.assertConfigurationError(.tenantId, .missing) {
            _ = try AgilCallConfiguration(serverURL: self.server, tenantId: " ", roomId: "demo")
        }
        TestSupport.assertConfigurationError(.tenantId, .invalidValue) {
            _ = try AgilCallConfiguration(serverURL: self.server, tenantId: "a/b", roomId: "demo")
        }
        TestSupport.assertConfigurationError(.tenantId, .tooLong) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                tenantId: String(repeating: "t", count: 65),
                roomId: "demo"
            )
        }
    }

    func testServerURLValidation() {
        TestSupport.assertConfigurationError(.serverURL, .invalidScheme) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "ftp://calls.example.com")!,
                roomId: "demo"
            )
        }
        TestSupport.assertConfigurationError(.serverURL, .insecureHTTP) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "http://calls.example.com")!,
                roomId: "demo"
            )
        }
        TestSupport.assertConfigurationError(.serverURL, .credentialsNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "https://user:pass@calls.example.com")!,
                roomId: "demo"
            )
        }
        TestSupport.assertConfigurationError(.serverURL, .queryOrFragmentNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "https://calls.example.com?token=x")!,
                roomId: "demo"
            )
        }
        TestSupport.assertConfigurationError(.serverURL, .queryOrFragmentNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "https://calls.example.com#fragment")!,
                roomId: "demo"
            )
        }
        TestSupport.assertConfigurationError(.serverURL, .notAnAbsoluteURL) {
            _ = try AgilCallConfiguration(serverURL: "not a url", roomId: "demo")
        }
    }

    func testLoopbackHTTPAndExplicitInsecureOptInAreAccepted() throws {
        let loopback = try AgilCallConfiguration(
            serverURL: URL(string: "http://localhost:8787")!,
            roomId: "demo"
        )
        XCTAssertEqual(loopback.widgetOrigin, "http://localhost:8787")

        let lan = try AgilCallConfiguration(
            serverURL: URL(string: "http://192.168.1.10:8787")!,
            roomId: "demo",
            allowsInsecureHTTP: true
        )
        XCTAssertEqual(lan.widgetOrigin, "http://192.168.1.10:8787")
    }

    func testTokenValidation() {
        TestSupport.assertConfigurationError(.joinToken, .containsWhitespace) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", joinToken: "a b")
        }
        TestSupport.assertConfigurationError(.joinToken, .containsControlCharacters) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", joinToken: "a\nb")
        }
        TestSupport.assertConfigurationError(.joinToken, .missing) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", joinToken: "")
        }
        TestSupport.assertConfigurationError(.joinToken, .tooLong) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                joinToken: String(repeating: "a", count: 8_193)
            )
        }
        TestSupport.assertConfigurationError(.identityToken, .tooLong) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                identityToken: String(repeating: "a", count: 16_385)
            )
        }
    }

    func testLanguageValidation() {
        XCTAssertEqual(
            try AgilCallConfiguration(serverURL: server, roomId: "demo", language: " ru ").language,
            "ru"
        )
        // BCP-47 input is accepted but normalized to the locales embed.html
        // actually understands.
        XCTAssertEqual(
            try AgilCallConfiguration(serverURL: server, roomId: "demo", language: "en-US").language,
            "en"
        )
        XCTAssertEqual(
            try AgilCallConfiguration(serverURL: server, roomId: "demo", language: "RU-ru").language,
            "ru"
        )
        TestSupport.assertConfigurationError(.language, .invalidLanguageTag) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", language: "english")
        }
        TestSupport.assertConfigurationError(.language, .invalidLanguageTag) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", language: "en_US")
        }
        TestSupport.assertConfigurationError(.language, .invalidLanguageTag) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", language: "de-DE")
        }
        TestSupport.assertConfigurationError(.language, .invalidLanguageTag) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", language: "pt-BR")
        }
    }

    func testServerURLNormalizationRejectsDotSegments() throws {
        let uppercase = try AgilCallConfiguration(
            serverURL: URL(string: "https://CALLS.Example.COM:443/calls/")!,
            roomId: "demo"
        )
        XCTAssertEqual(uppercase.serverURL.absoluteString, "https://calls.example.com/calls")
        XCTAssertEqual(uppercase.widgetOrigin, "https://calls.example.com")

        TestSupport.assertConfigurationError(.serverURL, .parentDirectorySegment) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "https://calls.example.com/a/../admin")!,
                roomId: "demo"
            )
        }
        TestSupport.assertConfigurationError(.serverURL, .parentDirectorySegment) {
            _ = try AgilCallConfiguration(
                serverURL: URL(string: "https://calls.example.com/a/%2e%2e/admin")!,
                roomId: "demo"
            )
        }
    }

    func testWidgetPathValidation() {
        TestSupport.assertConfigurationError(.widgetPath, .missing) {
            _ = try AgilCallConfiguration(serverURL: self.server, roomId: "demo", widgetPath: " ")
        }
        TestSupport.assertConfigurationError(.widgetPath, .pathMustBeRelative) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "https://evil.example.com/embed.html"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .pathMustBeRelative) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "//evil.example.com/embed.html"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .parentDirectorySegment) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "../embed.html"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .parentDirectorySegment) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "%2e%2e/embed.html"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .backslashNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "embed\\html"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .queryOrFragmentNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "embed.html?x=1"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .trailingSlashNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "embed.html/"
            )
        }
        TestSupport.assertConfigurationError(.widgetPath, .containsWhitespace) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                widgetPath: "embed html"
            )
        }
    }

    func testAllowedOriginsValidation() throws {
        TestSupport.assertConfigurationError(.allowedOrigins, .wildcardOriginNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: ["*"]
            )
        }
        TestSupport.assertConfigurationError(.allowedOrigins, .originMustNotContainPath) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: ["https://cdn.example.com/assets"]
            )
        }
        TestSupport.assertConfigurationError(.allowedOrigins, .invalidScheme) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: ["wss://cdn.example.com"]
            )
        }
        TestSupport.assertConfigurationError(.allowedOrigins, .insecureHTTP) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: ["http://cdn.example.com"]
            )
        }
        TestSupport.assertConfigurationError(.allowedOrigins, .insecureHTTP) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: ["http://192.168.1.10:8080"]
            )
        }
        TestSupport.assertConfigurationError(.allowedOrigins, .credentialsNotAllowed) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: ["https://user:pass@cdn.example.com"]
            )
        }
        TestSupport.assertConfigurationError(.allowedOrigins, .tooManyOrigins) {
            _ = try AgilCallConfiguration(
                serverURL: self.server,
                roomId: "demo",
                allowedOrigins: (0...32).map { "https://cdn\($0).example.com" }
            )
        }

        let deduplicated = try AgilCallConfiguration(
            serverURL: server,
            roomId: "demo",
            allowedOrigins: [
                "https://cdn.example.com",
                "https://CDN.example.com:443/",
                "https://calls.example.com"
            ]
        )
        XCTAssertEqual(
            deduplicated.allowedOrigins,
            ["https://cdn.example.com", "https://calls.example.com"]
        )

        let loopback = try AgilCallConfiguration(
            serverURL: server,
            roomId: "demo",
            allowedOrigins: ["http://localhost:8787", "http://127.0.0.1:3000"]
        )
        XCTAssertEqual(
            loopback.allowedOrigins,
            ["http://localhost:8787", "http://127.0.0.1:3000"]
        )

        let insecure = try AgilCallConfiguration(
            serverURL: server,
            roomId: "demo",
            allowedOrigins: ["http://cdn.example.com"],
            allowsInsecureHTTP: true
        )
        XCTAssertEqual(insecure.allowedOrigins, ["http://cdn.example.com"])
    }

    func testDescriptionNeverContainsTokens() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: server,
            roomId: "demo",
            joinToken: "super-secret-join-token",
            identityToken: "super-secret-identity-token"
        )
        let rendered = String(describing: configuration)
        XCTAssertFalse(rendered.contains("super-secret-join-token"))
        XCTAssertFalse(rendered.contains("super-secret-identity-token"))
        XCTAssertTrue(rendered.contains("hasJoinToken: true"))
        XCTAssertTrue(rendered.contains("hasIdentityToken: true"))
        XCTAssertFalse(configuration.debugDescription.contains("super-secret"))
    }

    func testConfigurationErrorDescriptionIsTokenFree() {
        let error = AgilConfigurationError(
            field: .joinToken,
            reason: .tooLong,
            limit: 8_192
        )
        XCTAssertEqual(error.errorDescription, "joinToken is too long (max 8192 characters)")
    }
}
