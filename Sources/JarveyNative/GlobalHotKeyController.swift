import Carbon.HIToolbox
import Foundation

// MARK: - Configurable push-to-talk hotkey

final class GlobalHotKeyController {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private let onPress: () -> Void
  private let onRelease: () -> Void

  init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
    self.onPress = onPress
    self.onRelease = onRelease
    installHandler()
    registerOptionSpace()
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
  }

  /// Re-register the hotkey from a settings string like "Option+Space", "Command+Shift+J", etc.
  func updateHotkey(_ descriptor: String) {
    guard let (keyCode, modifiers) = Self.parse(descriptor) else { return }
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    let hotKeyID = EventHotKeyID(signature: OSType(0x464C5244), id: UInt32(1))
    RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  private func installHandler() {
    var eventSpecs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      )
    ]

    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil,
          &hotKeyID
        )
        if hotKeyID.id == 1 {
          let ctrl = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
          let kind = GetEventKind(event)
          if kind == UInt32(kEventHotKeyPressed) {
            ctrl.onPress()
          } else if kind == UInt32(kEventHotKeyReleased) {
            ctrl.onRelease()
          }
        }
        return noErr
      },
      eventSpecs.count, &eventSpecs,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandlerRef
    )
  }

  private func registerOptionSpace() {
    let hotKeyID = EventHotKeyID(signature: OSType(0x464C5244), id: UInt32(1))
    RegisterEventHotKey(
      UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
      GetApplicationEventTarget(), 0, &hotKeyRef
    )
  }

  // MARK: - Hotkey string parsing

  /// Parse "Option+Space" style string into (keyCode, carbonModifiers).
  static func parse(_ descriptor: String) -> (UInt32, UInt32)? {
    let parts = descriptor
      .split(separator: "+")
      .map { $0.trimmingCharacters(in: .whitespaces) }

    guard !parts.isEmpty else { return nil }

    var modifiers: UInt32 = 0
    var keyName = ""

    for part in parts {
      switch part.lowercased() {
      case "option", "opt", "alt", "\u{2325}":
        modifiers |= UInt32(optionKey)
      case "command", "cmd", "\u{2318}":
        modifiers |= UInt32(cmdKey)
      case "shift", "\u{21E7}":
        modifiers |= UInt32(shiftKey)
      case "control", "ctrl", "\u{2303}":
        modifiers |= UInt32(controlKey)
      default:
        keyName = part.lowercased()
      }
    }

    guard let keyCode = keyCodeForName(keyName) else { return nil }
    return (keyCode, modifiers)
  }

  /// Human-readable display string for a hotkey descriptor.
  static func displayString(for descriptor: String) -> String {
    let parts = descriptor
      .split(separator: "+")
      .map { $0.trimmingCharacters(in: .whitespaces) }

    var symbols: [String] = []
    var keyDisplay = ""

    for part in parts {
      switch part.lowercased() {
      case "control", "ctrl", "\u{2303}":
        symbols.append("\u{2303}")
      case "option", "opt", "alt", "\u{2325}":
        symbols.append("\u{2325}")
      case "shift", "\u{21E7}":
        symbols.append("\u{21E7}")
      case "command", "cmd", "\u{2318}":
        symbols.append("\u{2318}")
      default:
        keyDisplay = displayNameForKey(part.lowercased())
      }
    }

    symbols.append(keyDisplay)
    return symbols.joined()
  }

  private static func displayNameForKey(_ name: String) -> String {
    switch name {
    case "space": return "Space"
    case "return", "enter": return "\u{21A9}"
    case "tab": return "\u{21E5}"
    case "escape", "esc": return "\u{238B}"
    case "delete", "backspace": return "\u{232B}"
    case "up": return "\u{2191}"
    case "down": return "\u{2193}"
    case "left": return "\u{2190}"
    case "right": return "\u{2192}"
    default: return name.uppercased()
    }
  }

  private static func keyCodeForName(_ name: String) -> UInt32? {
    switch name {
    case "space": return UInt32(kVK_Space)
    case "return", "enter": return UInt32(kVK_Return)
    case "tab": return UInt32(kVK_Tab)
    case "escape", "esc": return UInt32(kVK_Escape)
    case "delete", "backspace": return UInt32(kVK_Delete)
    case "up": return UInt32(kVK_UpArrow)
    case "down": return UInt32(kVK_DownArrow)
    case "left": return UInt32(kVK_LeftArrow)
    case "right": return UInt32(kVK_RightArrow)
    case "a": return UInt32(kVK_ANSI_A)
    case "b": return UInt32(kVK_ANSI_B)
    case "c": return UInt32(kVK_ANSI_C)
    case "d": return UInt32(kVK_ANSI_D)
    case "e": return UInt32(kVK_ANSI_E)
    case "f": return UInt32(kVK_ANSI_F)
    case "g": return UInt32(kVK_ANSI_G)
    case "h": return UInt32(kVK_ANSI_H)
    case "i": return UInt32(kVK_ANSI_I)
    case "j": return UInt32(kVK_ANSI_J)
    case "k": return UInt32(kVK_ANSI_K)
    case "l": return UInt32(kVK_ANSI_L)
    case "m": return UInt32(kVK_ANSI_M)
    case "n": return UInt32(kVK_ANSI_N)
    case "o": return UInt32(kVK_ANSI_O)
    case "p": return UInt32(kVK_ANSI_P)
    case "q": return UInt32(kVK_ANSI_Q)
    case "r": return UInt32(kVK_ANSI_R)
    case "s": return UInt32(kVK_ANSI_S)
    case "t": return UInt32(kVK_ANSI_T)
    case "u": return UInt32(kVK_ANSI_U)
    case "v": return UInt32(kVK_ANSI_V)
    case "w": return UInt32(kVK_ANSI_W)
    case "x": return UInt32(kVK_ANSI_X)
    case "y": return UInt32(kVK_ANSI_Y)
    case "z": return UInt32(kVK_ANSI_Z)
    case "0": return UInt32(kVK_ANSI_0)
    case "1": return UInt32(kVK_ANSI_1)
    case "2": return UInt32(kVK_ANSI_2)
    case "3": return UInt32(kVK_ANSI_3)
    case "4": return UInt32(kVK_ANSI_4)
    case "5": return UInt32(kVK_ANSI_5)
    case "6": return UInt32(kVK_ANSI_6)
    case "7": return UInt32(kVK_ANSI_7)
    case "8": return UInt32(kVK_ANSI_8)
    case "9": return UInt32(kVK_ANSI_9)
    case "f1": return UInt32(kVK_F1)
    case "f2": return UInt32(kVK_F2)
    case "f3": return UInt32(kVK_F3)
    case "f4": return UInt32(kVK_F4)
    case "f5": return UInt32(kVK_F5)
    case "f6": return UInt32(kVK_F6)
    case "f7": return UInt32(kVK_F7)
    case "f8": return UInt32(kVK_F8)
    case "f9": return UInt32(kVK_F9)
    case "f10": return UInt32(kVK_F10)
    case "f11": return UInt32(kVK_F11)
    case "f12": return UInt32(kVK_F12)
    default: return nil
    }
  }
}
