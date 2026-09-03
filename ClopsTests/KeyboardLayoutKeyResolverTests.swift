import XCTest
@testable import Clops

final class KeyboardLayoutKeyResolverTests: XCTestCase {
    func testFindsFirstVirtualKeyCodeProducingSemanticCharacter() {
        let result = KeyboardLayoutKeyResolver.firstVirtualKeyCode(
            producing: "v",
            keyCodes: UInt16(0)..<UInt16(6)
        ) { keyCode in
            switch keyCode {
            case 2, 4: "v"
            default: nil
            }
        }

        XCTAssertEqual(result, 2)
    }

    func testReturnsNilWhenLayoutCannotProduceSemanticCharacter() {
        let result = KeyboardLayoutKeyResolver.firstVirtualKeyCode(
            producing: "v",
            keyCodes: UInt16(0)..<UInt16(6)
        ) { _ in "x" }

        XCTAssertNil(result)
    }
}
