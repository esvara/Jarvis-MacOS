import Foundation

struct SidecarClient: Sendable {
  let baseURL: URL
  let authToken: String
  private static let requestTimeout: TimeInterval = 8

  init(
    baseURL: URL = LocalEndpoints.sidecarBaseURL,
    authToken: String = ""
  ) {
    self.baseURL = baseURL
    self.authToken = authToken
  }

  func health() async throws -> HealthSnapshot {
    try await request(path: "/health", method: "GET")
  }

  func settings() async throws -> SettingsData {
    try await request(path: "/settings", method: "GET")
  }

  func updateSettings(_ patch: SettingsPatch) async throws -> SettingsData {
    try await request(path: "/settings", method: "PUT", body: patch)
  }

  struct LocalVoiceTurnResult: Codable {
    var ok: Bool
    var reply: String?
    var error: String?
    var delegatedAgent: String?
  }

  struct LocalVoiceHealth: Codable {
    var running: Bool
    var model: String
    var modelPulled: Bool
  }

  func localVoiceHealth() async throws -> LocalVoiceHealth {
    try await request(path: "/local-voice/health", method: "GET")
  }

  /// Direct check of the Parakeet STT server's readiness (127.0.0.1:4821).
  func parakeetReady() async -> Bool {
    await parakeetHealth() == .ready
  }

  /// Tri-state health so callers can tell "server up, model still loading"
  /// (keep waiting) from "server unreachable" (stop waiting — the LaunchAgent
  /// is down, so polling for the full timeout is wasted).
  enum ParakeetHealth { case ready, loading, unreachable }

  func parakeetHealth() async -> ParakeetHealth {
    guard let url = URL(string: "http://127.0.0.1:4821/health") else { return .unreachable }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return .unreachable }
    struct Reply: Codable {
      var ready: Bool?
    }
    let ready = (try? JSONDecoder().decode(Reply.self, from: data))?.ready ?? false
    return ready ? .ready : .loading
  }

  struct LocalVoiceWarmupResult: Codable {
    var ok: Bool
    var error: String?
  }

  /// Loads the local LLM into memory; slow when cold, so generous timeout.
  func localVoiceWarmup() async throws -> LocalVoiceWarmupResult {
    struct Empty: Codable {}
    guard let url = URL(string: "/local-voice/warmup", relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &request)
    request.timeoutInterval = 70
    request.httpBody = try JSONEncoder().encode(Empty())
    let (data, response) = try await URLSession.shared.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  private struct LocalVoiceStreamLine: Codable {
    var delta: String?
    var done: Bool?
    var ok: Bool?
    var reply: String?
    var error: String?
    var delegatedAgent: String?
  }

  /// Streaming variant of localVoiceTurn: NDJSON deltas invoke onDelta as the
  /// model generates, and the final line resolves the returned result.
  func localVoiceTurnStream(
    text: String,
    language: String,
    onDelta: @escaping @Sendable (String) -> Void
  ) async throws -> LocalVoiceTurnResult {
    struct TurnBody: Codable {
      var text: String
      var language: String
    }
    guard let url = URL(string: "/local-voice/turn-stream", relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &request)
    request.timeoutInterval = 150
    request.httpBody = try JSONEncoder().encode(TurnBody(text: text, language: language))

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw SidecarClientError.invalidResponse
    }

    let decoder = JSONDecoder()
    for try await line in bytes.lines {
      guard let data = line.data(using: .utf8),
            let parsed = try? decoder.decode(LocalVoiceStreamLine.self, from: data) else {
        continue
      }
      if let delta = parsed.delta, !delta.isEmpty {
        onDelta(delta)
      }
      if parsed.done == true {
        return LocalVoiceTurnResult(
          ok: parsed.ok ?? false,
          reply: parsed.reply,
          error: parsed.error,
          delegatedAgent: parsed.delegatedAgent
        )
      }
    }
    throw SidecarClientError.invalidResponse
  }

  /// Local (Ollama) voice turn — the model may run several tool rounds, so
  /// this call uses its own generous timeout instead of the default 8 s.
  func localVoiceTurn(text: String, language: String) async throws -> LocalVoiceTurnResult {
    struct TurnBody: Codable {
      var text: String
      var language: String
    }
    guard let url = URL(string: "/local-voice/turn", relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &request)
    request.timeoutInterval = 150
    request.httpBody = try JSONEncoder().encode(TurnBody(text: text, language: language))
    let (data, response) = try await URLSession.shared.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  func validateApiKey() async throws -> ApiKeyValidation {
    try await request(
      path: "/openai/validate-key",
      method: "POST",
      body: EmptyBody()
    )
  }

  func recentMemories(limit: Int = 8) async throws -> [MemoryRecord] {
    try await request(path: "/memory/recent?limit=\(limit)", method: "GET")
  }

  func startTask(userRequest: String) async throws -> StartTaskResponse {
    struct Payload: Codable {
      var userRequest: String
    }

    return try await request(
      path: "/backend/tasks",
      method: "POST",
      body: Payload(userRequest: userRequest)
    )
  }

  func approve(taskId: String, approvalId: String) async throws {
    struct Payload: Codable {
      var approvalId: String
      var alwaysApply: Bool = false
    }

    _ = try await request(
      path: "/backend/tasks/\(taskId)/approve",
      method: "POST",
      body: Payload(approvalId: approvalId)
    ) as EmptyResponse
  }

  func reject(taskId: String, approvalId: String, message: String) async throws {
    struct Payload: Codable {
      var approvalId: String
      var alwaysApply: Bool = false
      var message: String
    }

    _ = try await request(
      path: "/backend/tasks/\(taskId)/reject",
      method: "POST",
      body: Payload(approvalId: approvalId, message: message)
    ) as EmptyResponse
  }

  func cancel(taskId: String) async throws {
    _ = try await request(
      path: "/backend/tasks/\(taskId)/cancel",
      method: "POST",
      body: EmptyBody()
    ) as EmptyResponse
  }

  func cancelAllTasks() async throws -> CancelAllResponse {
    try await request(
      path: "/backend/tasks/cancel-all",
      method: "POST",
      body: EmptyBody()
    )
  }

  func codexStatus() async throws -> CodexStatus {
    try await request(path: "/codex/status", method: "GET")
  }

  func agentsStatus() async throws -> AgentsStatusResponse {
    try await request(path: "/agents/status", method: "GET")
  }

  func recentCodexEvents(limit: Int = 24) async throws -> [CodexBridgeEvent] {
    try await request(path: "/codex/events/recent?limit=\(limit)", method: "GET")
  }

  func sendCodexCommand(_ command: CodexCommandRequest) async throws -> CodexCommandResult {
    try await request(
      path: "/codex/command",
      method: "POST",
      body: command
    )
  }

  func codexPmStatus(query: String? = nil, agent: String = "codex", quiet: Bool = false) async throws -> CodexPmStatus {
    struct Payload: Codable {
      var query: String?
      var agent: String?
      var quiet: Bool?
    }

    return try await request(
      path: "/codex/pm-status",
      method: "POST",
      body: Payload(query: query, agent: agent, quiet: quiet ? true : nil)
    )
  }

  func stopCodexBridge() async throws -> CodexCommandResult {
    try await request(
      path: "/codex/stop",
      method: "POST",
      body: EmptyBody()
    )
  }

  func eventBytes() async throws -> URLSession.AsyncBytes {
    guard let url = URL(string: "/backend/events", relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    applyAuth(to: &request)
    let (bytes, _) = try await URLSession.shared.bytes(for: request)
    return bytes
  }

  func recentBackendEvents(limit: Int = 24, taskId: String? = nil) async throws -> [BackendEvent] {
    var path = "/backend/events/recent?limit=\(limit)"
    if let taskId, !taskId.isEmpty {
      path += "&taskId=\(taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId)"
    }
    return try await request(path: path, method: "GET")
  }

  private func request<T: Decodable>(
    path: String,
    method: String
  ) async throws -> T {
    guard let url = URL(string: path, relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &request)
    request.timeoutInterval = Self.requestTimeout
    let (data, response) = try await URLSession.shared.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  private func request<T: Decodable, Body: Encodable>(
    path: String,
    method: String,
    body: Body
  ) async throws -> T {
    guard let url = URL(string: path, relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &request)
    request.timeoutInterval = Self.requestTimeout
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
    guard let http = response as? HTTPURLResponse else {
      throw SidecarClientError.invalidResponse
    }

    guard (200 ... 299).contains(http.statusCode) else {
      if let message = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
        throw SidecarClientError.server(message.error)
      }
      throw SidecarClientError.server("HTTP \(http.statusCode)")
    }

    return try JSONDecoder().decode(T.self, from: data)
  }

  private func applyAuth(to request: inout URLRequest) {
    guard !authToken.isEmpty else { return }
    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
  }
}

struct ApiKeyValidation: Decodable, Equatable {
  let valid: Bool
  let reason: String?
}

private struct ErrorResponse: Decodable {
  let error: String
}

private struct EmptyBody: Encodable {}

private struct EmptyResponse: Decodable {}

enum SidecarClientError: LocalizedError {
  case invalidResponse
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The sidecar returned an invalid response."
    case .server(let message):
      return message
    }
  }
}
