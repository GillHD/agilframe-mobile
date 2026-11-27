import XCTest
@testable import AgilCalls

/**
 * Pure tests for `AgilOriginNormalizer`. They need no simulator/WebView and are
 * meant to run from an Xcode test target (see `agil/mobile/capacitor/README.md`,
 * "Сборка и тесты"). The Windows QA host has no Swift toolchain, so this file is
 * checked statically there via `test/native-source.test.ts`.
 */
final class AgilOriginNormalizerTests: XCTestCase {
    func testURLDefaultsNormalizeToSchemeDefault() {
        XCTAssertEqual(AgilOriginNormalizer.normalize(urlString: "https://calls.example.com"), "https://calls.example.com")
        XCTAssertEqual(AgilOriginNormalizer.normalize(urlString: "https://calls.example.com:443"), "https://calls.example.com")
        XCTAssertEqual(AgilOriginNormalizer.normalize(urlString: "http://calls.example.com"), "http://calls.example.com")
        XCTAssertEqual(AgilOriginNormalizer.normalize(urlString: "http://calls.example.com:80"), "http://calls.example.com")
    }

    func testWebKitSecurityOriginPortZeroMeansSchemeDefault() {
        // WKWebView reports 0 for https://host and http://host.
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(securityScheme: "https", host: "calls.example.com", port: 0),
            "https://calls.example.com"
        )
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(securityScheme: "http", host: "calls.example.com", port: 0),
            "http://calls.example.com"
        )
        // The regression: a widget origin parsed from the URL must equal the
        // security-origin form, or every agil:* message is dropped on iOS.
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(urlString: "https://calls.example.com"),
            AgilOriginNormalizer.normalize(securityScheme: "https", host: "calls.example.com", port: 0)
        )
    }

    func testNonDefaultPortsArePreserved() {
        XCTAssertEqual(AgilOriginNormalizer.normalize(urlString: "https://host:8443/calls"), "https://host:8443")
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(securityScheme: "https", host: "host", port: 8443),
            "https://host:8443"
        )
        // https on port 80 is not the https default and must stay explicit.
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(securityScheme: "https", host: "host", port: 80),
            "https://host:80"
        )
        // http on 443 must not collapse to the https origin.
        XCTAssertNotEqual(
            AgilOriginNormalizer.normalize(securityScheme: "http", host: "host", port: 443),
            AgilOriginNormalizer.normalize(securityScheme: "https", host: "host", port: 0)
        )
    }

    func testHostCaseAndPathsAreCanonicalised() {
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(urlString: "HTTPS://Calls.Example.COM/calls/embed.html?room=r"),
            "https://calls.example.com"
        )
        XCTAssertEqual(
            AgilOriginNormalizer.normalize(securityScheme: "HTTPS", host: "Calls.Example.COM", port: 0),
            "https://calls.example.com"
        )
    }

    func testUnsafeOriginsAreRejected() {
        XCTAssertNil(AgilOriginNormalizer.normalize(urlString: "javascript:alert(1)"))
        XCTAssertNil(AgilOriginNormalizer.normalize(urlString: "file:///etc/passwd"))
        XCTAssertNil(AgilOriginNormalizer.normalize(urlString: "https://user:pass@host"))
        XCTAssertNil(AgilOriginNormalizer.normalize(urlString: "https://host:0/embed.html"))
        XCTAssertNil(AgilOriginNormalizer.normalize(securityScheme: "https", host: "", port: 0))
        XCTAssertNil(AgilOriginNormalizer.normalize(securityScheme: "data", host: "host", port: 0))
        XCTAssertNil(AgilOriginNormalizer.normalize(securityScheme: "https", host: "host/path", port: 0))
    }
}
