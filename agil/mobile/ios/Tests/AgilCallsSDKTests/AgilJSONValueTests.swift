import Foundation
import XCTest
@testable import AgilCallsSDK

final class AgilJSONValueTests: XCTestCase {
    func testIntValueRejectsFractionalNumbers() {
        XCTAssertEqual(AgilJSONValue.number(2).intValue, 2)
        XCTAssertNil(AgilJSONValue.number(2.9).intValue)
        XCTAssertNil(AgilJSONValue.number(-1.5).intValue)
        XCTAssertNil(AgilJSONValue.number(.infinity).intValue)
    }
}
