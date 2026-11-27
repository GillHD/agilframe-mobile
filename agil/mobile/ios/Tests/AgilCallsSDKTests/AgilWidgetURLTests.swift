import Foundation
import XCTest
@testable import AgilCallsSDK

final class AgilWidgetURLTests: XCTestCase {
    private let server = TestSupport.server

    func testBuildsCanonicalEmbedURL() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: server,
            tenantId: "demo",
            roomId: "demo-room",
            joinToken: "tok+en/value=",
            participantName: "Алиса",
            theme: .dark,
            language: "ru",
            relayOnly: true,
            identityToken: "identity.token.value"
        )

        let url = try AgilWidgetURL.build(configuration)
        XCTAssertEqual(url.path, "/embed.html")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "calls.example.com")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            return items.first { $0.name == name }?.value
        }

        XCTAssertEqual(value("server"), "https://calls.example.com")
        XCTAssertEqual(value("room"), "demo-room")
        XCTAssertEqual(value("token"), "tok+en/value=")
        XCTAssertEqual(value("tenant"), "demo")
        XCTAssertEqual(value("lang"), "ru")
        XCTAssertEqual(value("name"), "Алиса")
        XCTAssertEqual(value("identity_token"), "identity.token.value")
        XCTAssertEqual(value("theme"), "dark")
        XCTAssertEqual(value("relay"), "1")
    }

    func testPlusAndSlashArePercentEncodedInTheQueryValue() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: server,
            roomId: "demo",
            joinToken: "a+b/c="
        )
        let url = try AgilWidgetURL.build(configuration)
        // `+` must be %2B: servers commonly decode `+` in a query as a space.
        XCTAssertTrue(url.absoluteString.contains("token=a%2Bb%2Fc%3D"))
        XCTAssertFalse(url.absoluteString.contains("token=a+b"))
    }

    func testSubpathServerKeepsTheWidgetUnderTheSubpath() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: URL(string: "https://calls.example.com/calls")!,
            roomId: "demo"
        )
        let url = try AgilWidgetURL.build(configuration)
        XCTAssertEqual(url.path, "/calls/embed.html")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "server" }?.value,
            "https://calls.example.com/calls"
        )
    }

    func testRootWidgetPathEscapesTheSubpathButNotTheOrigin() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: URL(string: "https://calls.example.com/calls")!,
            roomId: "demo",
            widgetPath: "/embed.html"
        )
        let url = try AgilWidgetURL.build(configuration)
        XCTAssertEqual(url.path, "/embed.html")
        XCTAssertEqual(AgilValidation.origin(of: url), "https://calls.example.com")
    }

    func testURLContainsNoWildcardTargetOrigin() throws {
        let configuration = try AgilCallConfiguration(
            serverURL: server,
            roomId: "demo",
            joinToken: "token"
        )
        let url = try AgilWidgetURL.build(configuration)
        XCTAssertFalse(url.absoluteString.contains("*"))
    }

    func testNavigationAllowlist() {
        let origins: Set<String> = [
            "https://calls.example.com",
            "https://cdn.example.com"
        ]

        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://calls.example.com/embed.html?room=demo")!,
            allowedOrigins: origins
        ))
        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://CALLS.example.com:443/assets/app.js")!,
            allowedOrigins: origins
        ))
        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://cdn.example.com/font.woff2")!,
            allowedOrigins: origins
        ))
        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "about:blank")!,
            allowedOrigins: origins
        ))
        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "about:srcdoc")!,
            allowedOrigins: origins
        ))

        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://evil.example.com/embed.html")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "http://calls.example.com/embed.html")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://calls.example.com:8443/embed.html")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://calls.example.com@evil.example.com/embed.html")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "https://calls.example.com.evil.example.com/embed.html")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "javascript:alert(1)")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "file:///etc/passwd")!,
            allowedOrigins: origins
        ))
        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "about:config")!,
            allowedOrigins: origins
        ))
    }

    func testNavigationDoesNotTrustPlainHTTPByDefault() {
        let origins: Set<String> = ["https://cdn.example.com", "http://cdn.example.com"]

        XCTAssertFalse(AgilWidgetURL.isAllowedNavigation(
            URL(string: "http://cdn.example.com/font.woff2")!,
            allowedOrigins: origins
        ))
        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "http://cdn.example.com/font.woff2")!,
            allowedOrigins: origins,
            allowsInsecureHTTP: true
        ))

        let loopback: Set<String> = ["http://localhost:8787"]
        XCTAssertTrue(AgilWidgetURL.isAllowedNavigation(
            URL(string: "http://localhost:8787/embed.html")!,
            allowedOrigins: loopback
        ))
    }

    func testOriginCanonicalization() {
        XCTAssertEqual(
            AgilValidation.origin(of: URL(string: "https://CALLS.example.com:443/a/b?x=1#f")!),
            "https://calls.example.com"
        )
        XCTAssertEqual(
            AgilValidation.origin(of: URL(string: "http://localhost:8787/embed.html")!),
            "http://localhost:8787"
        )
        XCTAssertEqual(
            AgilValidation.origin(of: URL(string: "https://[::1]:8443/embed.html")!),
            "https://[::1]:8443"
        )
        XCTAssertNil(AgilValidation.origin(of: URL(string: "ftp://calls.example.com")!))
        XCTAssertNil(AgilValidation.origin(of: URL(string: "https://user:pass@calls.example.com")!))
    }

    func testTokenTextRedaction() {
        let text = """
        token=secret-at-start
        join failed for token=secret-value and identity_token=identity-value
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk
        Authorization: Bearer abc.def.ghi
        """
        let redacted = AgilRedaction.redactTokenText(text)
        XCTAssertFalse(redacted.contains("secret-at-start"))
        XCTAssertFalse(redacted.contains("secret-value"))
        XCTAssertFalse(redacted.contains("identity-value"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"))
        XCTAssertFalse(redacted.contains("Bearer abc.def.ghi"))
        XCTAssertTrue(redacted.contains("token=redacted"))
        XCTAssertTrue(redacted.contains("redacted"))
    }

    func testURLRedaction() throws {
        let url = try XCTUnwrap(URL(string:
            "https://calls.example.com/embed.html?server=https%3A%2F%2Fcalls.example.com&room=demo&token=secret-token&identity_token=identity-token"
        ))
        let rendered = AgilRedaction.redactURL(url)
        XCTAssertFalse(rendered.contains("secret-token"))
        XCTAssertFalse(rendered.contains("identity-token"))
        XCTAssertTrue(rendered.contains("room=demo"))
        XCTAssertTrue(rendered.contains("token=redacted"))
    }

    func testURLRedactionRemovesCredentials() throws {
        let url = try XCTUnwrap(URL(string: "https://user:pass@calls.example.com/embed.html?room=demo"))
        let rendered = AgilRedaction.redactURL(url)
        XCTAssertFalse(rendered.contains("user"))
        XCTAssertFalse(rendered.contains("pass"))
    }

    func testBenignTextIsUnchanged() {
        let text = "Room demo joined with 3 participants"
        XCTAssertEqual(AgilRedaction.redactTokenText(text), text)
    }

    func testRedactionCoversCamelCaseAndEncodedAssignments() {
        let text = """
        joinToken=abc123&identityToken%3Dxyz789
        apiKey = key-value access_token=access-value
        token%3Dencoded-secret
        """
        let redacted = AgilRedaction.redactTokenText(text)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("xyz789"))
        XCTAssertFalse(redacted.contains("key-value"))
        XCTAssertFalse(redacted.contains("access-value"))
        XCTAssertFalse(redacted.contains("encoded-secret"))
        XCTAssertTrue(redacted.contains("joinToken=redacted"))
        XCTAssertTrue(redacted.contains("token%3Dredacted"))
    }
}
