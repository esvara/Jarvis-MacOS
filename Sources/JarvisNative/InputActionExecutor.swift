import Foundation
import CoreGraphics

struct InputActionExecutor {
  private enum Timing {
    static let clickDownUpDelay: useconds_t = 30_000
    static let doubleClickGap: useconds_t = 20_000
    static let moveBeforeScrollDelay: useconds_t = 20_000
    static let keypressDelay: useconds_t = 20_000
    static let modifierDelay: useconds_t = 10_000
    static let characterDelay: useconds_t = 8_000
    static let dragStepDelay: useconds_t = 10_000
    static let dragStartDelay: useconds_t = 50_000
    static let focusSettleDelay: useconds_t = 150_000
    static let keyboardSettleDelay: useconds_t = 120_000
    static let pointerSettleDelay: useconds_t = 60_000
  }

  func execute(_ action: InputAction) throws {
    try performAction(action)
  }

  private func performAction(_ action: InputAction) throws {
    switch action.type {
    case .click:
      postClick(
        x: try required(action.x, named: "x"),
        y: try required(action.y, named: "y"),
        button: action.button ?? .left)
    case .doubleClick:
      postDoubleClick(
        x: try required(action.x, named: "x"),
        y: try required(action.y, named: "y"),
        button: action.button ?? .left)
    case .move:
      postMove(
        x: try required(action.x, named: "x"),
        y: try required(action.y, named: "y"))
    case .scroll:
      postScroll(
        x: try required(action.x, named: "x"),
        y: try required(action.y, named: "y"),
        scrollX: try required(action.scrollX, named: "scrollX"),
        scrollY: try required(action.scrollY, named: "scrollY"))
    case .type:
      postType(text: try required(action.text, named: "text"))
    case .keypress:
      let keys = try required(action.keys, named: "keys")
      try postKeypress(keys: keys)
    case .hotkey:
      let combo = try required(action.combo, named: "combo")
      try postHotkey(combo: combo)
    case .drag:
      if let path = action.path, path.count >= 2 {
        postDrag(points: path.map { CGPoint(x: $0.x, y: $0.y) })
        return
      }
      guard let fromX = action.fromX,
            let fromY = action.fromY,
            let toX = action.toX,
            let toY = action.toY else {
        throw InputActionError.invalidField("drag requires a path with at least two points")
      }
      postDrag(points: interpolatedDragPoints(fromX: fromX, fromY: fromY, toX: toX, toY: toY))
    }
  }

  private func required<T>(_ value: T?, named field: String) throws -> T {
    guard let value else {
      throw InputActionError.missingField(field)
    }
    return value
  }

  private func postClick(x: Double, y: Double, button: MouseButtonName) {
    let point = CGPoint(x: x, y: y)
    let spec = mouseEventSpec(for: button)
    let down = makeMouseEvent(type: spec.downType, point: point, spec: spec)
    let up = makeMouseEvent(type: spec.upType, point: point, spec: spec)
    down?.post(tap: .cghidEventTap)
    usleep(Timing.clickDownUpDelay)
    up?.post(tap: .cghidEventTap)
    usleep(Timing.focusSettleDelay)
  }

  private func postDoubleClick(x: Double, y: Double, button: MouseButtonName) {
    let point = CGPoint(x: x, y: y)
    let spec = mouseEventSpec(for: button)
    let down1 = makeMouseEvent(type: spec.downType, point: point, spec: spec)
    let up1 = makeMouseEvent(type: spec.upType, point: point, spec: spec)
    let down2 = makeMouseEvent(type: spec.downType, point: point, spec: spec)
    let up2 = makeMouseEvent(type: spec.upType, point: point, spec: spec)
    down2?.setIntegerValueField(.mouseEventClickState, value: 2)
    up2?.setIntegerValueField(.mouseEventClickState, value: 2)
    down1?.post(tap: .cghidEventTap)
    usleep(Timing.doubleClickGap)
    up1?.post(tap: .cghidEventTap)
    usleep(Timing.doubleClickGap)
    down2?.post(tap: .cghidEventTap)
    usleep(Timing.doubleClickGap)
    up2?.post(tap: .cghidEventTap)
    usleep(Timing.focusSettleDelay)
  }

  private func postMove(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    let event = CGEvent(
      mouseEventSource: nil,
      mouseType: .mouseMoved,
      mouseCursorPosition: point,
      mouseButton: .left)
    event?.post(tap: .cghidEventTap)
    usleep(Timing.pointerSettleDelay)
  }

  private func postScroll(x: Double, y: Double, scrollX: Double, scrollY: Double) {
    postMove(x: x, y: y)
    usleep(Timing.moveBeforeScrollDelay)

    let dy = Int32(-scrollY / 120)
    let dx = Int32(-scrollX / 120)
    let event = CGEvent(
      scrollWheelEvent2Source: nil,
      units: .line,
      wheelCount: 2,
      wheel1: dy,
      wheel2: dx,
      wheel3: 0)
    event?.post(tap: .cgSessionEventTap)
    usleep(Timing.pointerSettleDelay)
  }

  private func postType(text: String) {
    // Clear any lingering modifier flags so characters aren't misread as shortcuts.
    let emptyFlags: CGEventFlags = []
    for char in text {
      let uniChar = Array(String(char).utf16)
      let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      down?.keyboardSetUnicodeString(stringLength: uniChar.count, unicodeString: uniChar)
      up?.keyboardSetUnicodeString(stringLength: uniChar.count, unicodeString: uniChar)
      down?.flags = emptyFlags
      up?.flags = emptyFlags
      down?.post(tap: .cghidEventTap)
      usleep(Timing.characterDelay)
      up?.post(tap: .cghidEventTap)
      usleep(Timing.characterDelay)
    }
    usleep(Timing.keyboardSettleDelay)
  }

  private func postKeypress(keys: [String]) throws {
    switch try KeyboardActionParser.parseKeypress(keys) {
    case .singleModifier(let modifier):
      postModifierEvent(modifier, keyDown: true, flags: modifier.flag)
      usleep(Timing.keypressDelay)
      postModifierEvent(modifier, keyDown: false, flags: modifier.flag)
    case .singleKey(let keyCode):
      let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
      let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
      down?.post(tap: .cghidEventTap)
      usleep(Timing.keypressDelay)
      up?.post(tap: .cghidEventTap)
    case .combo(let parsedHotkey):
      postHotkey(parsedHotkey)
    }
    usleep(Timing.keyboardSettleDelay)
  }

  private func postModifierEvent(_ modifier: KeyboardModifier, keyDown: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier.keyCode, keyDown: keyDown)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
  }

  private func postHotkey(combo: String) throws {
    let parsedHotkey = try KeyboardActionParser.parseHotkey(combo)
    postHotkey(parsedHotkey)
  }

  private func postHotkey(_ parsedHotkey: ParsedHotkey) {
    var activeFlags: CGEventFlags = []

    for modifier in parsedHotkey.modifiers {
      activeFlags.insert(modifier.flag)
      postModifierEvent(modifier, keyDown: true, flags: activeFlags)
      usleep(Timing.modifierDelay)
    }

    for keyCode in parsedHotkey.keyCodes {
      let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
      down?.flags = activeFlags
      down?.post(tap: .cghidEventTap)
      usleep(Timing.keypressDelay)
    }

    for keyCode in parsedHotkey.keyCodes.reversed() {
      let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
      up?.flags = activeFlags
      up?.post(tap: .cghidEventTap)
      usleep(Timing.keypressDelay)
    }

    for modifier in parsedHotkey.modifiers.reversed() {
      let flagsBeforeRelease = activeFlags
      activeFlags.remove(modifier.flag)
      postModifierEvent(modifier, keyDown: false, flags: flagsBeforeRelease)
      usleep(Timing.modifierDelay)
    }
    usleep(Timing.keyboardSettleDelay)
  }

  private func postDrag(points: [CGPoint], button: MouseButtonName = .left) {
    guard let start = points.first, let end = points.last else { return }
    let spec = mouseEventSpec(for: button)

    let down = makeMouseEvent(type: spec.downType, point: start, spec: spec)
    down?.post(tap: .cghidEventTap)
    usleep(Timing.dragStartDelay)

    for point in points.dropFirst() {
      let drag = makeMouseEvent(type: spec.dragType, point: point, spec: spec)
      drag?.post(tap: .cghidEventTap)
      usleep(Timing.dragStepDelay)
    }

    let up = makeMouseEvent(type: spec.upType, point: end, spec: spec)
    up?.post(tap: .cghidEventTap)
    usleep(Timing.focusSettleDelay)
  }

  private func interpolatedDragPoints(
    fromX: Double,
    fromY: Double,
    toX: Double,
    toY: Double,
    steps: Int = 10
  ) -> [CGPoint] {
    let start = CGPoint(x: fromX, y: fromY)
    guard steps > 0 else {
      return [start, CGPoint(x: toX, y: toY)]
    }

    var points = [start]
    for i in 1...steps {
      let t = Double(i) / Double(steps)
      points.append(
        CGPoint(
          x: fromX + (toX - fromX) * t,
          y: fromY + (toY - fromY) * t))
    }
    return points
  }

  private func mouseEventSpec(for button: MouseButtonName) -> MouseEventSpec {
    switch button {
    case .left:
      return MouseEventSpec(
        mouseButton: .left,
        buttonNumber: 0,
        downType: .leftMouseDown,
        upType: .leftMouseUp,
        dragType: .leftMouseDragged)
    case .right:
      return MouseEventSpec(
        mouseButton: .right,
        buttonNumber: 1,
        downType: .rightMouseDown,
        upType: .rightMouseUp,
        dragType: .rightMouseDragged)
    case .wheel:
      return MouseEventSpec(
        mouseButton: .center,
        buttonNumber: 2,
        downType: .otherMouseDown,
        upType: .otherMouseUp,
        dragType: .otherMouseDragged)
    case .back:
      return MouseEventSpec(
        mouseButton: .center,
        buttonNumber: 3,
        downType: .otherMouseDown,
        upType: .otherMouseUp,
        dragType: .otherMouseDragged)
    case .forward:
      return MouseEventSpec(
        mouseButton: .center,
        buttonNumber: 4,
        downType: .otherMouseDown,
        upType: .otherMouseUp,
        dragType: .otherMouseDragged)
    }
  }

  private func makeMouseEvent(type: CGEventType, point: CGPoint, spec: MouseEventSpec) -> CGEvent? {
    let event = CGEvent(
      mouseEventSource: nil,
      mouseType: type,
      mouseCursorPosition: point,
      mouseButton: spec.mouseButton)
    event?.setIntegerValueField(.mouseEventButtonNumber, value: spec.buttonNumber)
    return event
  }
}
