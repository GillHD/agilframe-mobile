import XCTest
@testable import AgilCallsSDK

/// Shared assertions/helpers for the pure unit tests.
enum TestSupport {
    static let server = URL(string: "https://calls.example.com")!

    static func assertConfigurationError(
        _ field: AgilConfigurationError.Field,
        _ reason: AgilConfigurationError.Reason,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail(
                "Expected AgilConfigurationError \(field.rawValue).\(reason.rawValue)",
                file: file,
                line: line
            )
        } catch let error as AgilConfigurationError {
            XCTAssertEqual(error.field, field, file: file, line: line)
            XCTAssertEqual(error.reason, reason, file: file, line: line)
        } catch {
            XCTFail("Expected AgilConfigurationError, got \(error)", file: file, line: line)
        }
    }

    static func jsonData(_ object: Any) -> Data {
        // Test fixtures are literals; invalid JSON here is a test bug.
        return try! JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func jsonString(_ object: Any) -> String {
        return String(data: jsonData(object), encoding: .utf8)!
    }

    /// Wraps a widget message the way the injected shim does.
    static func bridgeEnvelope(_ object: Any, nonce: String) -> String {
        return jsonString([
            "__agilBridgeNonce": nonce,
            "message": jsonString(object)
        ])
    }

    static func httpResponse(
        status: Int,
        headers: [String: String]? = nil,
        url: URL = URL(string: "https://calls.example.com/v1/rooms/demo/join")!
    ) -> HTTPURLResponse {
        return HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
