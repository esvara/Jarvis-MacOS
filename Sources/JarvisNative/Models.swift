import Foundation

/// Single source of truth for the Node sidecar's loopback port.
/// Override with the JARVIS_SIDECAR_PORT environment variable.
enum LocalEndpoints {
  static let sidecarPort: Int =
    ProcessInfo.processInfo.environment["JARVIS_SIDECAR_PORT"].flatMap(Int.init) ?? 4818

  static var sidecarBaseURL: URL {
    URL(string: "http://127.0.0.1:\(sidecarPort)")!
  }
}

struct ToolRegistryConfig: Codable {
  var enableWebSearch: Bool
  var enableCodeInterpreter: Bool
  var enableImageGeneration: Bool
  var enableOpenClawBackend: Bool
  var vectorStoreIds: [String]
}

struct CodexIntegrationConfig: Codable {
  var enabled: Bool
  var godMode: Bool
  var mode: String
  var inboxPath: String
  var outboxPath: String
  var eventsPath: String
  var driveExpiresAt: String?
}

struct SettingsData: Codable {
  var appName: String
  var apiKey: String
  var hasApiKey: Bool
  var hotkey: String
  var voice: String
  var voiceInputMode: String
  var language: String?
  var debugMode: Bool
  var autonomyMode: String
  var browserControlMode: String
  var codexIntegration: CodexIntegrationConfig
  var toolRegistry: ToolRegistryConfig

  static let empty = SettingsData(
    appName: "Jarvis",
    apiKey: "",
    hasApiKey: false,
    hotkey: "Option+Space",
    voice: "cedar",
    voiceInputMode: "push_to_talk",
    language: "es",
    debugMode: false,
    autonomyMode: "maximum",
    browserControlMode: "headless",
    codexIntegration: CodexIntegrationConfig(
      enabled: true,
      godMode: false,
      mode: "assist",
      inboxPath: "~/Library/Application Support/Jarvis/codex/inbox.md",
      outboxPath: "~/Library/Application Support/Jarvis/codex/outbox.md",
      eventsPath: "~/Library/Application Support/Jarvis/codex/events.jsonl",
      driveExpiresAt: nil
    ),
    toolRegistry: ToolRegistryConfig(
      enableWebSearch: true,
      enableCodeInterpreter: true,
      enableImageGeneration: true,
      enableOpenClawBackend: false,
      vectorStoreIds: []
    )
  )
}

struct SettingsPatch: Codable {
  var apiKey: String?
  var hotkey: String?
  var voice: String?
  var voiceInputMode: String?
  var language: String?
  var browserControlMode: String?
  var autonomyMode: String?
  var codexIntegration: CodexIntegrationConfig?
}

struct AgentStatusRow: Codable, Identifiable {
  var agent: String
  var running: Bool
  var installed: Bool
  var pid: Int?

  var id: String { agent }

  var displayName: String {
    switch agent {
    case "codex": return "Codex"
    case "claude": return "Claude"
    default: return agent.capitalized
    }
  }
}

struct AgentsStatusResponse: Codable {
  var agents: [AgentStatusRow]
}

struct HealthSnapshot: Codable {
  var ok: Bool
  var pid: Int
  var inputServerAvailable: Bool
  var inputServerVersion: String?
  var hasApiKey: Bool
  var secured: Bool?
  var activeTaskIds: [String]?

  static let offline = HealthSnapshot(
    ok: false,
    pid: 0,
    inputServerAvailable: false,
    inputServerVersion: nil,
    hasApiKey: false,
    secured: nil,
    activeTaskIds: nil
  )
}

struct MemoryRecord: Codable, Identifiable {
  var id: String
  var kind: String
  var subject: String
  var content: String
  var confidence: Double
  var source: String
  var tags: [String]
  var createdAt: String
  var updatedAt: String
}

struct ApprovalRequest: Codable, Identifiable {
  var id: String
  var taskId: String
  var kind: String
  var toolName: String
  var summary: String
  var detail: String?
  var createdAt: String
}

struct BackendTaskResult: Codable {
  var taskId: String
  var summary: String
  var outputText: String
  var agent: String
  var completedAt: String
}

struct BackendEvent: Codable, Identifiable {
  var taskId: String
  var type: String
  var createdAt: String
  var summary: String?
  var detail: String?
  var approvalId: String?
  var approval: ApprovalRequest?
  var result: BackendTaskResult?
  var imageBase64: String?

  var id: String {
    "\(taskId)-\(createdAt)-\(type)"
  }
}

struct StartTaskResponse: Codable {
  var taskId: String
}

struct CancelAllResponse: Codable {
  var ok: Bool
  var cancelled: [String]?
}

struct CodexBridgeEvent: Codable, Identifiable {
  var id: String
  var type: String
  var createdAt: String
  var summary: String
  var detail: String?
  var command: String?
}

struct CodexStatus: Codable {
  var enabled: Bool
  var mode: String
  var codexRunning: Bool
  var codexPid: Int?
  var queueDepth: Int
  var heartbeatAt: String
  var inboxPath: String
  var outboxPath: String
  var eventsPath: String
  var driveExpiresAt: String?
  var lastEvent: CodexBridgeEvent?

  static let empty = CodexStatus(
    enabled: true,
    mode: "assist",
    codexRunning: false,
    codexPid: nil,
    queueDepth: 0,
    heartbeatAt: "",
    inboxPath: "~/Library/Application Support/Jarvis/codex/inbox.md",
    outboxPath: "~/Library/Application Support/Jarvis/codex/outbox.md",
    eventsPath: "~/Library/Application Support/Jarvis/codex/events.jsonl",
    driveExpiresAt: nil,
    lastEvent: nil
  )
}

struct CodexCommandRequest: Codable {
  var intent: String
  var command: String
  var modeHint: String?
  var requireConfirmation: Bool?
}

struct CodexCommandResult: Codable {
  var status: String
  var summary: String
  var nextAction: String?
  var needsUserApproval: Bool
  var pmPrompt: String?
  var event: CodexBridgeEvent?
}

struct CodexPmStatus: Codable {
  var ok: Bool
  var summary: String
  var codexRunning: Bool
  var needsUserAttention: Bool
  var currentState: String
  var lastReadableText: String?
  var lastEvent: CodexBridgeEvent?
  var capturedAt: String

  static let empty = CodexPmStatus(
    ok: false,
    summary: "No Codex status yet.",
    codexRunning: false,
    needsUserAttention: false,
    currentState: "unknown",
    lastReadableText: nil,
    lastEvent: nil,
    capturedAt: ""
  )
}

struct NativePermissionSnapshot: Equatable {
  var microphone: String
  var screen: String
  var accessibilityTrusted: Bool
  var voiceRuntimeSupported: Bool
}

struct TranscriptEntry: Codable, Identifiable {
  var id: String
  var role: String
  var text: String
  var timestamp: String
  var agent: String?
}

struct VoiceApprovalState: Codable {
  var id: String
  var title: String
  var detail: String?
}

struct VoiceRuntimeState: Codable {
  var connected: Bool
  var muted: Bool
  var phase: String
  var currentAgent: String
  var level: Double
}

struct OverlayActionCallout: Equatable {
  var label: String
  var text: String
}
