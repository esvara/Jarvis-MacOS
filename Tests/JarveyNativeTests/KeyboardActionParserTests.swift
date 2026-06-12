@testable import JarveyNative
import XCTest

final class KeyboardActionParserTests: XCTestCase {
  func testRejectsUnsupportedSingleKey() {
    XCTAssertThrowsError(try KeyboardActionParser.parseKeypress(["definitely-not-a-key"])) { error in
      XCTAssertEqual(
        error as? InputActionError,
        .invalidField("Unsupported key 'definitely-not-a-key'"))
    }
  }

  func testRejectsUnsupportedHotkeyToken() {
    XCTAssertThrowsError(try KeyboardActionParser.parseHotkey("cmd,launch-missiles")) { error in
      XCTAssertEqual(
        error as? InputActionError,
        .invalidField("Unsupported key 'launch-missiles' in combo"))
    }
  }

  func testParsesValidHotkey() throws {
    XCTAssertEqual(
      try KeyboardActionParser.parseHotkey("cmd,shift,t"),
      ParsedHotkey(modifiers: [.command, .shift], keyCodes: [17]))
  }
}
