import Foundation
import Network
import ApplicationServices
import AppKit

/// Lightweight HTTP server that accepts input-action requests from the sidecar
/// and executes them via CGEvent inside JarvisNative's process (which has
/// Accessibility permission). Listens on 127.0.0.1:<port>.
final class InputActionServer: @unchecked Sendable {
  private let listener: NWListener
  private let executor = InputActionExecutor()
  private let screenCaptureController = ScreenCaptureController()
  private let permissionCoordinator: PermissionCoordinator
  private let authToken: String
  private var actionsBlocked = false
  @MainActor private var lastDeliveryVerified = false
  @MainActor private var lastDeliveryHandoff = false
  let port: UInt16

  init(
    port: UInt16 = 4819,
    permissionCoordinator: PermissionCoordinator,
    authToken: String
  ) throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let endpointPort = NWEndpoint.Port(rawValue: port)!
    if let loopback = IPv4Address("127.0.0.1") {
      params.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: endpointPort)
    }
    let listener = try NWListener(using: params)
    self.listener = listener
    self.port = port
    self.permissionCoordinator = permissionCoordinator
    self.authToken = authToken
  }

  func start() {
    listener.newConnectionHandler = { [weak self] connection in
      self?.handleConnection(connection)
    }
    listener.start(queue: .global(qos: .userInteractive))
  }

  func stop() {
    listener.cancel()
  }

  private func handleConnection(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInteractive))
    receiveRequest(on: connection, buffer: Data())
  }

  private func receiveRequest(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }

      if error != nil {
        self.sendResponse(
          connection: connection,
          status: 400,
          body: self.responseJSON(ok: false, error: "Request transport failed"))
        return
      }

      var nextBuffer = buffer
      if let data {
        nextBuffer.append(data)
      }

      do {
        switch try InputActionRequestParser.parse(nextBuffer) {
        case .incomplete:
          if isComplete {
            self.sendResponse(
              connection: connection,
              status: 400,
              body: self.responseJSON(ok: false, error: "Incomplete HTTP request"))
            return
          }
          self.receiveRequest(on: connection, buffer: nextBuffer)
        case .ready(let request):
          self.handle(request, connection: connection)
        }
      } catch let error as InputActionRequestParserError {
        self.sendResponse(
          connection: connection,
          status: 400,
          body: self.responseJSON(ok: false, error: error.message))
      } catch {
        self.sendResponse(
          connection: connection,
          status: 400,
          body: self.responseJSON(ok: false, error: error.localizedDescription))
      }
    }
  }

  private func handle(_ request: InputActionRequest, connection: NWConnection) {
    switch request {
    case .health:
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        self.sendResponse(
          connection: connection,
          status: 200,
          body: self.responseJSON(
            ok: true,
            extra: [
              "trusted": snapshot.accessibilityTrusted,
              "accessibilityTrusted": snapshot.accessibilityTrusted,
              "screen": snapshot.screen,
              "microphone": snapshot.microphone,
              "voiceRuntimeSupported": snapshot.voiceRuntimeSupported,
              "actionsBlocked": self.actionsBlocked
            ]))
      }
    case .screenshot(let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        guard !self.actionsBlocked else {
          self.sendResponse(
            connection: connection,
            status: 409,
            body: self.responseJSON(ok: false, error: "Input actions are paused by Stop All."))
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        guard snapshot.screen == "granted" else {
          self.sendResponse(
            connection: connection,
            status: 403,
            body: self.responseJSON(
              ok: false,
              error: "Screen Recording permission is required. Grant access in Privacy & Security > Screen Recording."))
          return
        }

        do {
          let screenshot = try await self.screenCaptureController.captureBase64PNG()
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: true, extra: ["data": screenshot]))
        } catch {
          self.sendResponse(
            connection: connection,
            status: 500,
            body: self.responseJSON(ok: false, error: error.localizedDescription))
        }
      }
    case .action(let action, let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        guard !self.actionsBlocked else {
          self.sendResponse(
            connection: connection,
            status: 409,
            body: self.responseJSON(ok: false, error: "Input actions are paused by Stop All."))
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        self.sendResponse(
          connection: connection,
          status: snapshot.accessibilityTrusted ? 200 : 403,
          body: self.executeAction(action, permissions: snapshot))
      }
    case .emergencyStop(let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }
        self.actionsBlocked = true
        self.sendResponse(connection: connection, status: 200, body: self.responseJSON(ok: true))
      }
    case .resumeActions(let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }
        self.actionsBlocked = false
        self.sendResponse(connection: connection, status: 200, body: self.responseJSON(ok: true))
      }
    case .agentStatus(let appKey, let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }
        guard let target = AgentAppTarget(rawValue: appKey.lowercased()) else {
          self.sendResponse(
            connection: connection,
            status: 400,
            body: self.responseJSON(ok: false, error: "Unknown agent app '\(appKey)'"))
          return
        }
        let app = self.findAgentApplication(target)
        var extra: [String: Any] = [
          "running": app != nil,
          "name": app?.localizedName ?? target.displayName,
          "installed": FileManager.default.fileExists(atPath: target.applicationPath)
        ]
        if let app {
          extra["pid"] = Int(app.processIdentifier)
        }
        self.sendResponse(
          connection: connection,
          status: 200,
          body: self.responseJSON(ok: true, extra: extra))
      }
    case .agentRead(let appKey, let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        guard let target = AgentAppTarget(rawValue: appKey.lowercased()) else {
          self.sendResponse(
            connection: connection,
            status: 400,
            body: self.responseJSON(ok: false, error: "Unknown agent app '\(appKey)'"))
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        guard snapshot.accessibilityTrusted else {
          self.sendResponse(
            connection: connection,
            status: 403,
            body: self.responseJSON(ok: false, error: "Accessibility permission is required to read \(target.displayName)."))
          return
        }

        do {
          let text = try self.readAgentAccessibleText(target)
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: true, extra: [
              "running": true,
              "text": text,
              "capturedAt": ISO8601DateFormatter().string(from: Date())
            ]))
        } catch {
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: false, error: error.localizedDescription, extra: [
              "running": self.findAgentApplication(target) != nil,
              "text": "",
              "capturedAt": ISO8601DateFormatter().string(from: Date())
            ]))
        }
      }
    case .agentSendPrompt(let prompt, let appKey, let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        guard !self.actionsBlocked else {
          self.sendResponse(
            connection: connection,
            status: 409,
            body: self.responseJSON(ok: false, error: "Input actions are paused by Stop All."))
          return
        }

        guard let target = AgentAppTarget(rawValue: appKey.lowercased()) else {
          self.sendResponse(
            connection: connection,
            status: 400,
            body: self.responseJSON(ok: false, error: "Unknown agent app '\(appKey)'"))
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        guard snapshot.accessibilityTrusted else {
          self.sendResponse(
            connection: connection,
            status: 403,
            body: self.responseJSON(
              ok: false,
              error: "Accessibility permission is required to drive \(target.displayName)."))
          return
        }

        do {
          try await self.deliverPrompt(prompt, to: target)
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: true, extra: [
              "verified": self.lastDeliveryVerified,
              "handoff": self.lastDeliveryHandoff
            ]))
        } catch {
          self.sendResponse(
            connection: connection,
            status: 500,
            body: self.responseJSON(ok: false, error: error.localizedDescription))
        }
      }
    case .appPaste(let body, let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        guard !self.actionsBlocked else {
          self.sendResponse(
            connection: connection,
            status: 409,
            body: self.responseJSON(ok: false, error: "Input actions are paused by Stop All."))
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        guard snapshot.accessibilityTrusted else {
          self.sendResponse(
            connection: connection,
            status: 403,
            body: self.responseJSON(ok: false, error: "Accessibility permission is required to paste into apps."))
          return
        }

        do {
          let verified = try await self.pasteText(
            body.text,
            intoAppNamed: body.app,
            submit: body.submit ?? false)
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: true, extra: ["verified": verified]))
        } catch {
          self.sendResponse(
            connection: connection,
            status: 500,
            body: self.responseJSON(ok: false, error: error.localizedDescription))
        }
      }
    case .appClick(let body, let authorization):
      guard isAuthorized(authorization) else {
        sendResponse(
          connection: connection,
          status: 401,
          body: responseJSON(ok: false, error: "Unauthorized"))
        return
      }
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        guard !self.actionsBlocked else {
          self.sendResponse(
            connection: connection,
            status: 409,
            body: self.responseJSON(ok: false, error: "Input actions are paused by Stop All."))
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        guard snapshot.accessibilityTrusted else {
          self.sendResponse(
            connection: connection,
            status: 403,
            body: self.responseJSON(ok: false, error: "Accessibility permission is required to click in apps."))
          return
        }

        do {
          let clickedLabel = try await self.clickElement(labelled: body.label, inAppNamed: body.app)
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: true, extra: ["clicked": clickedLabel]))
        } catch {
          self.sendResponse(
            connection: connection,
            status: 500,
            body: self.responseJSON(ok: false, error: error.localizedDescription))
        }
      }
    }
  }

  private func isAuthorized(_ authorization: String?) -> Bool {
    guard !authToken.isEmpty else {
      return false
    }
    return authorization == "Bearer \(authToken)"
  }

  private func executeAction(
    _ action: InputAction,
    permissions snapshot: NativePermissionSnapshot
  ) -> String {
    guard snapshot.accessibilityTrusted else {
      return responseJSON(
        ok: false,
        error: "Accessibility permission is required. Grant access in Privacy & Security > Accessibility.")
    }

    do {
      try executor.execute(action)
      return responseJSON(ok: true)
    } catch let error as InputActionError {
      return responseJSON(ok: false, error: error.message)
    } catch {
      return responseJSON(ok: false, error: error.localizedDescription)
    }
  }

  @MainActor
  private func findAgentApplication(_ target: AgentAppTarget) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { app in
      if app.bundleIdentifier?.localizedCaseInsensitiveContains(target.bundleHint) == true {
        return true
      }
      if let name = app.localizedName,
         name.compare(target.displayName, options: [.caseInsensitive]) == .orderedSame {
        return true
      }
      return app.bundleURL?.path == target.applicationPath
    }
  }

  @MainActor
  private func deliverPrompt(_ prompt: String, to target: AgentAppTarget) async throws {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw InputActionError.invalidField("\(target.displayName) prompt must not be empty")
    }

    var app = findAgentApplication(target)
    if app == nil {
      let url = URL(fileURLWithPath: target.applicationPath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw InputActionError.invalidField("\(target.displayName).app was not found in /Applications")
      }
      NSWorkspace.shared.open(url)
      app = try await waitForApplication(matching: { self.findAgentApplication(target) }, timeoutMs: 12_000)
    }

    guard let app else {
      throw InputActionError.invalidField("\(target.displayName) is not running and could not be opened")
    }

    // Reset before delivering so a thrown error can't leave the previous
    // delivery's outcome behind for the response handler to report.
    lastDeliveryVerified = false
    lastDeliveryHandoff = false

    let outcome = try await pasteAndVerify(
      trimmed,
      into: app,
      displayName: target.displayName,
      submit: true,
      requireTextInput: false,
      openNewChat: true)
    lastDeliveryVerified = outcome == .verified
    lastDeliveryHandoff = outcome == .handoff
  }

  /// Open (if needed) an arbitrary app by display name and paste text into its
  /// focused text field. Returns true when the pasted text was verified via AX.
  @MainActor
  private func pasteText(_ text: String, intoAppNamed appName: String, submit: Bool) async throws -> Bool {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw InputActionError.invalidField("text must not be empty")
    }
    guard !trimmedName.isEmpty else {
      throw InputActionError.invalidField("app must not be empty")
    }

    func findByName() -> NSRunningApplication? {
      NSWorkspace.shared.runningApplications.first { app in
        guard let name = app.localizedName else { return false }
        return name.compare(trimmedName, options: [.caseInsensitive]) == .orderedSame
          || name.localizedCaseInsensitiveContains(trimmedName)
      }
    }

    var app = findByName()
    if app == nil {
      // Launch by name the same way `open -a` does.
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-a", trimmedName]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw InputActionError.invalidField("Could not find or open an app named '\(trimmedName)'")
      }
      app = try await waitForApplication(matching: findByName, timeoutMs: 12_000)
    }

    guard let app else {
      throw InputActionError.invalidField("'\(trimmedName)' did not finish launching")
    }

    let outcome = try await pasteAndVerify(trimmedText, into: app, displayName: trimmedName, submit: submit, requireTextInput: false)
    return outcome == .verified
  }

  /// Activate an app by display name and press the first clickable element
  /// (button/link/menu button) whose title, description or value matches the
  /// label. Returns the matched element's actual label.
  @MainActor
  private func clickElement(labelled label: String, inAppNamed appName: String) async throws -> String {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
      throw InputActionError.invalidField("label must not be empty")
    }
    guard !trimmedName.isEmpty else {
      throw InputActionError.invalidField("app must not be empty")
    }

    guard let app = NSWorkspace.shared.runningApplications.first(where: { running in
      guard let name = running.localizedName else { return false }
      return name.compare(trimmedName, options: [.caseInsensitive]) == .orderedSame
        || name.localizedCaseInsensitiveContains(trimmedName)
    }) else {
      throw InputActionError.invalidField("'\(trimmedName)' is not running")
    }

    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    try await Task.sleep(for: .milliseconds(600))

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    try await Task.sleep(for: .milliseconds(500))

    var match = findClickable(labelled: trimmedLabel, in: axApp)
    if match == nil {
      try await Task.sleep(for: .milliseconds(900))
      match = findClickable(labelled: trimmedLabel, in: axApp)
    }
    guard let match else {
      throw InputActionError.invalidField(
        "No clickable element matching '\(trimmedLabel)' was found in \(trimmedName)")
    }

    let pressResult = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
    guard pressResult == .success else {
      throw InputActionError.invalidField(
        "Found '\(match.label)' in \(trimmedName) but pressing it failed")
    }
    return match.label
  }

  @MainActor
  private func findClickable(
    labelled label: String,
    in axApp: AXUIElement
  ) -> (element: AXUIElement, label: String)? {
    let clickableRoles = Set([
      kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, "AXLink",
      kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole
    ].map { $0 as String })

    guard let window = copyAXAttribute(axApp, kAXFocusedWindowAttribute) else {
      return nil
    }
    var found: [AXUIElement] = []
    var visited = 0
    // Buttons can sit deep inside Electron content trees — search much deeper
    // than the text-input scan.
    findElements(
      withRoles: clickableRoles,
      from: window as! AXUIElement,
      depth: 0,
      results: &found,
      visited: &visited,
      maxDepth: 30,
      maxVisited: 6_000)

    for element in found {
      let candidates = [
        copyAXAttribute(element, kAXTitleAttribute) as? String,
        copyAXAttribute(element, kAXDescriptionAttribute) as? String,
        copyAXAttribute(element, kAXValueAttribute) as? String
      ]
      for candidate in candidates {
        if let candidate, !candidate.isEmpty,
           candidate.localizedCaseInsensitiveContains(label) {
          return (element, candidate)
        }
      }
    }
    return nil
  }

  @MainActor
  private func waitForApplication(
    matching find: () -> NSRunningApplication?,
    timeoutMs: Int
  ) async throws -> NSRunningApplication? {
    var waited = 0
    while waited < timeoutMs {
      if let app = find(), app.isFinishedLaunching {
        return app
      }
      try await Task.sleep(for: .milliseconds(300))
      waited += 300
    }
    return find()
  }

  /// Activate the app, wait until it is actually frontmost, focus a text input
  /// via Accessibility when possible, paste, verify, and optionally submit.
  enum DeliveryOutcome {
    case verified
    case blind
    case handoff
  }

  @MainActor
  private func pasteAndVerify(
    _ text: String,
    into app: NSRunningApplication,
    displayName: String,
    submit: Bool,
    requireTextInput: Bool,
    openNewChat: Bool = false
  ) async throws -> DeliveryOutcome {
    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

    var waited = 0
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
          waited < 8_000 {
      try await Task.sleep(for: .milliseconds(200))
      waited += 200
      if waited % 2_000 == 0 {
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
      }
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
      throw InputActionError.invalidField("\(displayName) did not come to the foreground")
    }
    // Give the freshly-activated window a moment to settle its first responder.
    try await Task.sleep(for: .milliseconds(600))

    if openNewChat {
      // Each delegation goes into a fresh conversation so it never lands as a
      // follow-up in (or interferes with) a thread that is mid-task.
      try executor.execute(InputAction(
        type: .hotkey, x: nil, y: nil, button: nil, text: nil, keys: nil,
        combo: "cmd,n", scrollX: nil, scrollY: nil,
        fromX: nil, fromY: nil, toX: nil, toY: nil, path: nil))
      try await Task.sleep(for: .milliseconds(1_200))
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    // Electron/Chromium apps keep their AX tree disabled until asked; without
    // this, Electron-based apps may expose no text inputs at all.
    AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    try await Task.sleep(for: .milliseconds(500))
    var textInput = focusTextInput(in: axApp)
    if textInput == nil {
      // The tree can take a moment to materialize after enabling.
      try await Task.sleep(for: .milliseconds(900))
      textInput = focusTextInput(in: axApp)
    }
    if requireTextInput, textInput == nil {
      // Editor app whose chat box Accessibility cannot reach (Chromium forks
      // expose only the menu bar): hand off instead of pasting blind — leave
      // the brief on the clipboard with the app frontmost for a manual Cmd+V.
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
      return .handoff
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    try executor.execute(InputAction(
      type: .hotkey, x: nil, y: nil, button: nil, text: nil, keys: nil,
      combo: "cmd,v", scrollX: nil, scrollY: nil,
      fromX: nil, fromY: nil, toX: nil, toY: nil, path: nil))
    try await Task.sleep(for: .milliseconds(400))

    var verified = false
    if let textInput {
      verified = pasteLandedAnywhere(text, rememberedInput: textInput, axApp: axApp)
      if !verified {
        // Electron AX values can lag well behind the visible UI — wait and re-check
        // before re-pasting.
        try await Task.sleep(for: .milliseconds(700))
        verified = pasteLandedAnywhere(text, rememberedInput: textInput, axApp: axApp)
      }
      if !verified {
        // One retry: refocus, select-all so the re-paste REPLACES instead of
        // appending (a false-negative verification otherwise duplicates the
        // prompt in the box), then paste again.
        AXUIElementSetAttributeValue(textInput, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(200))
        try executor.execute(InputAction(
          type: .hotkey, x: nil, y: nil, button: nil, text: nil, keys: nil,
          combo: "cmd,a", scrollX: nil, scrollY: nil,
          fromX: nil, fromY: nil, toX: nil, toY: nil, path: nil))
        try await Task.sleep(for: .milliseconds(150))
        try executor.execute(InputAction(
          type: .hotkey, x: nil, y: nil, button: nil, text: nil, keys: nil,
          combo: "cmd,v", scrollX: nil, scrollY: nil,
          fromX: nil, fromY: nil, toX: nil, toY: nil, path: nil))
        try await Task.sleep(for: .milliseconds(600))
        verified = pasteLandedAnywhere(text, rememberedInput: textInput, axApp: axApp)
      }
      // Even when AX can't confirm the value (contenteditable boxes often expose
      // no AXValue), the paste went into a focused text input we located ourselves
      // — proceed as a blind delivery instead of aborting before the submit.
    }

    if submit {
      try executor.execute(InputAction(
        type: .keypress, x: nil, y: nil, button: nil, text: nil, keys: ["return"],
        combo: nil, scrollX: nil, scrollY: nil,
        fromX: nil, fromY: nil, toX: nil, toY: nil, path: nil))
    }
    return verified ? .verified : .blind
  }

  /// The paste may land in a different AX node than the one we remembered
  /// (Chromium re-creates nodes; the real first responder can differ), so check
  /// the remembered input, the app's current focused element, and the focused
  /// window's text inputs.
  @MainActor
  private func pasteLandedAnywhere(
    _ text: String,
    rememberedInput: AXUIElement,
    axApp: AXUIElement
  ) -> Bool {
    if pastedTextLanded(text, in: rememberedInput) {
      return true
    }
    if let focused = copyAXAttribute(axApp, kAXFocusedUIElementAttribute) {
      if pastedTextLanded(text, in: focused as! AXUIElement) {
        return true
      }
    }
    let textRoles = Set([kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].map { $0 as String })
    if let window = copyAXAttribute(axApp, kAXFocusedWindowAttribute) {
      var found: [AXUIElement] = []
      var visited = 0
      findElements(
        withRoles: textRoles,
        from: window as! AXUIElement,
        depth: 0,
        results: &found,
        visited: &visited)
      for element in found where pastedTextLanded(text, in: element) {
        return true
      }
    }
    return false
  }

  /// Locate a text input in the app's focused window and focus it. Prefers the
  /// already-focused element when it is editable. Returns nil when none found
  /// (caller falls back to a blind paste into the current first responder).
  @MainActor
  private func focusTextInput(in axApp: AXUIElement) -> AXUIElement? {
    let textRoles = Set([kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].map { $0 as String })

    if let focused = copyAXAttribute(axApp, kAXFocusedUIElementAttribute) {
      let element = focused as! AXUIElement
      if let role = copyAXAttribute(element, kAXRoleAttribute) as? String, textRoles.contains(role) {
        return element
      }
    }

    guard let window = copyAXAttribute(axApp, kAXFocusedWindowAttribute) else {
      return nil
    }
    var found: [AXUIElement] = []
    var visited = 0
    findElements(
      withRoles: textRoles,
      from: window as! AXUIElement,
      depth: 0,
      results: &found,
      visited: &visited)
    // Chat-style prompt boxes sit at the bottom of the window, which AX
    // enumerates last — prefer the last editable element found.
    guard let element = found.last else {
      return nil
    }
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    return element
  }

  private func findElements(
    withRoles roles: Set<String>,
    from element: AXUIElement,
    depth: Int,
    results: inout [AXUIElement],
    visited: inout Int,
    maxDepth: Int = 12,
    maxVisited: Int = 600
  ) {
    guard depth < maxDepth, visited < maxVisited else { return }
    visited += 1

    if let role = copyAXAttribute(element, kAXRoleAttribute) as? String, roles.contains(role) {
      results.append(element)
    }
    if let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
      for child in children {
        findElements(
          withRoles: roles, from: child, depth: depth + 1, results: &results,
          visited: &visited, maxDepth: maxDepth, maxVisited: maxVisited)
      }
    }
  }

  private func pastedTextLanded(_ text: String, in element: AXUIElement) -> Bool {
    guard let value = copyAXAttribute(element, kAXValueAttribute) as? String else {
      return false
    }
    let needle = String(text.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return false }
    return value.contains(needle)
  }

  @MainActor
  private func readAgentAccessibleText(_ target: AgentAppTarget) throws -> String {
    guard let app = findAgentApplication(target) else {
      throw InputActionError.invalidField("\(target.displayName) is not running")
    }

    let root = AXUIElementCreateApplication(app.processIdentifier)
    var values: [String] = []
    var visited = Set<ObjectIdentifier>()
    collectAccessibleText(from: root, depth: 0, values: &values, visited: &visited)

    let deduped = values.reduce(into: [String]()) { acc, value in
      let cleaned = value
        .replacingOccurrences(of: "\u{fffc}", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard cleaned.count > 1, !acc.contains(cleaned) else { return }
      acc.append(cleaned)
    }

    let joined = deduped.joined(separator: "\n")
    if joined.count > 30_000 {
      return String(joined.suffix(30_000))
    }
    return joined
  }

  private func collectAccessibleText(
    from element: AXUIElement,
    depth: Int,
    values: inout [String],
    visited: inout Set<ObjectIdentifier>
  ) {
    guard depth < 9, values.count < 260 else {
      return
    }

    let id = ObjectIdentifier(element)
    guard !visited.contains(id) else {
      return
    }
    visited.insert(id)

    for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
      if let value = copyAXAttribute(element, attribute), let text = value as? String {
        values.append(text)
      }
    }

    if let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
      for child in children {
        collectAccessibleText(from: child, depth: depth + 1, values: &values, visited: &visited)
      }
    }
  }

  private func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else {
      return nil
    }
    return value
  }

  private func sendResponse(connection: NWConnection, status: Int, body: String) {
    let phrase: String
    switch status {
    case 200:
      phrase = "OK"
    case 401:
      phrase = "Unauthorized"
    case 403:
      phrase = "Forbidden"
    case 409:
      phrase = "Conflict"
    case 500:
      phrase = "Internal Server Error"
    default:
      phrase = "Bad Request"
    }
    let header = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
    let response = Data((header + body).utf8)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func responseJSON(ok: Bool, error: String? = nil, extra: [String: Any] = [:]) -> String {
    var response = extra
    response["ok"] = ok
    if let error {
      response["error"] = error
    }

    guard let data = try? JSONSerialization.data(withJSONObject: response),
          let json = String(data: data, encoding: .utf8) else {
      return #"{"ok":false,"error":"Failed to encode response"}"#
    }
    return json
  }
}
