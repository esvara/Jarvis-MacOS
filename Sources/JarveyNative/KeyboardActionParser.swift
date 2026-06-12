import Foundation
import CoreGraphics

enum KeyboardActionParser {
  private static let keyCodeMap: [String: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
    "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
    "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
    "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
    "8": 28, "9": 25,
    "space": 49, "return": 36, "enter": 36, "tab": 9, "escape": 53, "esc": 53,
    "delete": 51, "backspace": 51, "forwarddelete": 117,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
    ",": 43, ".": 47, "/": 44, "`": 50,
  ]

  static func parseKeypress(_ keys: [String]) throws -> ParsedKeyboardAction {
    let normalizedKeys = normalizedTokens(keys)
    guard !normalizedKeys.isEmpty else {
      throw InputActionError.invalidField("keys must not be empty")
    }

    if normalizedKeys.count == 1 {
      let token = normalizedKeys[0]
      if let modifier = keyboardModifier(for: token) {
        return .singleModifier(modifier)
      }
      if let keyCode = keyCodeFor(token) {
        return .singleKey(keyCode)
      }
      throw InputActionError.invalidField("Unsupported key '\(token)'")
    }

    return .combo(try parseHotkey(normalizedKeys.joined(separator: ",")))
  }

  static func parseHotkey(_ combo: String) throws -> ParsedHotkey {
    let parts = normalizedTokens(combo.split(separator: ",").map(String.init))
    guard !parts.isEmpty else {
      throw InputActionError.invalidField("combo must not be empty")
    }

    var modifiers: [KeyboardModifier] = []
    var keyCodes: [CGKeyCode] = []

    for part in parts {
      if let modifier = keyboardModifier(for: part) {
        if !modifiers.contains(modifier) {
          modifiers.append(modifier)
        }
        continue
      }
      if let keyCode = keyCodeFor(part) {
        keyCodes.append(keyCode)
        continue
      }
      throw InputActionError.invalidField("Unsupported key '\(part)' in combo")
    }

    guard !modifiers.isEmpty || !keyCodes.isEmpty else {
      throw InputActionError.invalidField("combo must contain a supported key")
    }

    return ParsedHotkey(modifiers: modifiers, keyCodes: keyCodes)
  }

  static func keyCodeFor(_ name: String) -> CGKeyCode? {
    keyCodeMap[name.lowercased()]
  }

  static func keyboardModifier(for key: String) -> KeyboardModifier? {
    switch key {
    case "cmd", "command", "meta":
      return .command
    case "shift":
      return .shift
    case "alt", "option", "opt":
      return .option
    case "ctrl", "control":
      return .control
    default:
      return nil
    }
  }

  private static func normalizedTokens(_ values: [String]) -> [String] {
    values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
  }
}
