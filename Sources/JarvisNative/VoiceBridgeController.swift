import AppKit
import Foundation
import WebKit

enum VoiceBridgeEvent {
  case ready
  case state(VoiceRuntimeState)
  case transcript([TranscriptEntry])
  case realtimeApproval(VoiceApprovalState?)
  case error(String)
  case memoryChanged
  case taskState(String?)
}

@MainActor
protocol VoiceRuntimeControlling: AnyObject {
  func connect(startMuted: Bool) async throws
  func close() async
  func interrupt() async
  func setMuted(_ muted: Bool) async throws
  func approveApproval(alwaysApprove: Bool) async throws
  func rejectApproval(message: String?, alwaysReject: Bool) async throws
}

@MainActor
final class VoiceBridgeController: NSObject, VoiceRuntimeControlling {
  private let webView: WKWebView
  private let onEvent: (VoiceBridgeEvent) -> Void
  private let authToken: String
  private var isReady = false
  private var readyContinuations: [CheckedContinuation<Void, Never>] = []

  init(hostView: NSView, authToken: String = "", onEvent: @escaping (VoiceBridgeEvent) -> Void) {
    self.onEvent = onEvent
    self.authToken = authToken

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.allowsAirPlayForMediaPlayback = false

    self.webView = WKWebView(frame: .zero, configuration: configuration)

    super.init()

    configuration.userContentController.add(
      self,
      contentWorld: .page,
      name: AppIdentity.voiceMessageHandlerName
    )

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.alphaValue = 0.01
    hostView.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.widthAnchor.constraint(equalToConstant: 1),
      webView.heightAnchor.constraint(equalToConstant: 1),
      webView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
      webView.topAnchor.constraint(equalTo: hostView.topAnchor)
    ])

    var request = URLRequest(url: LocalEndpoints.sidecarBaseURL.appending(path: "voice-host"))
    if !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    webView.load(request)
  }

  func connect(startMuted: Bool) async throws {
    try await awaitReady(timeoutNanoseconds: 5_000_000_000)
    try await call(command: [
      "type": "connect",
      "muted": startMuted
    ])
  }

  func close() async {
    guard isReady else {
      return
    }

    try? await call(command: [
      "type": "close"
    ])
  }

  func interrupt() async {
    guard isReady else {
      return
    }

    try? await call(command: [
      "type": "interrupt"
    ])
  }

  func setMuted(_ muted: Bool) async throws {
    try await awaitReady(timeoutNanoseconds: 5_000_000_000)
    try await call(command: [
      "type": "setMuted",
      "muted": muted
    ])
  }

  func approveApproval(alwaysApprove: Bool) async throws {
    try await awaitReady(timeoutNanoseconds: 5_000_000_000)
    try await call(command: [
      "type": "approveApproval",
      "alwaysApprove": alwaysApprove
    ])
  }

  func rejectApproval(message: String?, alwaysReject: Bool) async throws {
    try await awaitReady(timeoutNanoseconds: 5_000_000_000)
    var command: [String: Any] = [
      "type": "rejectApproval",
      "alwaysReject": alwaysReject
    ]
    command["message"] = message ?? NSNull()
    try await call(command: command)
  }

  private func waitUntilReady() async {
    if isReady {
      return
    }

    await withCheckedContinuation { continuation in
      readyContinuations.append(continuation)
    }
  }

  private func awaitReady(timeoutNanoseconds: UInt64) async throws {
    if isReady {
      return
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [weak self] in
        await self?.waitUntilReady()
      }

      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)
        throw VoiceBridgeError.runtimeNotReady
      }

      _ = try await group.next()
      group.cancelAll()
    }
  }

  private func markReady() {
    guard !isReady else {
      return
    }

    isReady = true
    readyContinuations.forEach { $0.resume() }
    readyContinuations.removeAll(keepingCapacity: false)
    onEvent(.ready)
  }

  private func call(command: [String: Any]) async throws {
    try await withCheckedThrowingContinuation { continuation in
      webView.callAsyncJavaScript(
        "return await window.\(AppIdentity.voiceBridgeObjectName).receive(command)",
        arguments: ["command": command],
        in: nil,
        in: .page
      ) { result in
        switch result {
        case .success:
          continuation.resume()
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(T.self, from: data)
  }
}

extension VoiceBridgeController: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard
      message.name == AppIdentity.voiceMessageHandlerName,
      let body = message.body as? [String: Any],
      let type = body["type"] as? String
    else {
      return
    }

    do {
      switch type {
      case "ready":
        markReady()
      case "state":
        onEvent(.state(try decode(body, as: VoiceRuntimeState.self)))
      case "transcript":
        let envelope = try decode(body, as: TranscriptEnvelope.self)
        onEvent(.transcript(envelope.entries))
      case "realtimeApproval":
        let approval = try decode(body, as: RealtimeApprovalEnvelope.self)
        onEvent(.realtimeApproval(approval.approval))
      case "error":
        let envelope = try decode(body, as: ErrorEnvelope.self)
        onEvent(.error(envelope.message))
      case "memoryChanged":
        onEvent(.memoryChanged)
      case "taskState":
        let envelope = try decode(body, as: TaskStateEnvelope.self)
        onEvent(.taskState(envelope.taskId))
      default:
        break
      }
    } catch {
      onEvent(.error(error.localizedDescription))
    }
  }
}

extension VoiceBridgeController: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    isReady = false
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    onEvent(.error(error.localizedDescription))
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    onEvent(.error(error.localizedDescription))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isReady = false
    onEvent(.error("The voice runtime web content process terminated."))
  }
}

enum VoiceBridgeError: LocalizedError {
  case runtimeNotReady

  var errorDescription: String? {
    switch self {
    case .runtimeNotReady:
      return "The voice runtime did not finish loading."
    }
  }
}

extension VoiceBridgeController: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
    initiatedBy frame: WKFrameInfo,
    type: WKMediaCaptureType
  ) async -> WKPermissionDecision {
    .grant
  }
}

private struct TranscriptEnvelope: Decodable {
  let entries: [TranscriptEntry]
}

private struct RealtimeApprovalEnvelope: Decodable {
  let approval: VoiceApprovalState?
}

private struct ErrorEnvelope: Decodable {
  let message: String
}

private struct TaskStateEnvelope: Decodable {
  let taskId: String?
}
