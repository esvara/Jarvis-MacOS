export const memoryKinds = [
  "preference",
  "environment_fact",
  "app_alias",
  "workflow_default",
  "safe_macro"
] as const;

export type MemoryKind = (typeof memoryKinds)[number];

export type PermissionStatus =
  | "not-determined"
  | "granted"
  | "denied"
  | "restricted"
  | "unknown";

export type ApprovalKind =
  | "computer"
  | "shell"
  | "apply_patch"
  | "function"
  | "memory";

export type TaskPhase =
  | "idle"
  | "connecting"
  | "listening"
  | "thinking"
  | "speaking"
  | "acting"
  | "approvals"
  | "error";

export interface MemoryRecord {
  id: string;
  kind: MemoryKind;
  subject: string;
  content: string;
  confidence: number;
  source: string;
  tags: string[];
  createdAt: string;
  updatedAt: string;
}

export interface MemorySaveInput {
  kind: MemoryKind;
  subject: string;
  content: string;
  confidence: number;
  source: string;
  tags?: string[];
}

export interface MemorySearchInput {
  query: string;
  kinds?: MemoryKind[];
  limit?: number;
}

export interface MemoryForgetInput {
  id?: string;
  query?: string;
}

export type MemoryDecision = "allow" | "approval_required" | "block";

export interface MemoryPolicyResult {
  decision: MemoryDecision;
  reason: string;
  normalizedTags: string[];
}

export interface TranscriptEntry {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  timestamp: string;
  agent?: string;
}

export interface BackendTaskInput {
  requestId: string;
  userRequest: string;
  transcriptHistory: TranscriptEntry[];
  activeAppHint?: string;
  memoryContext?: string;
}

export interface BackendTaskResult {
  taskId: string;
  summary: string;
  outputText: string;
  agent: string;
  completedAt: string;
}

export interface ApprovalRequest {
  id: string;
  taskId: string;
  kind: ApprovalKind;
  toolName: string;
  summary: string;
  detail?: string;
  rawItem: unknown;
  createdAt: string;
}

export type BackendTaskEvent =
  | {
      taskId: string;
      type: "started";
      createdAt: string;
      summary: string;
    }
  | {
      taskId: string;
      type: "delegated";
      createdAt: string;
      summary: string;
      detail?: string;
    }
  | {
      taskId: string;
      type: "approval_requested";
      createdAt: string;
      approval: ApprovalRequest;
    }
  | {
      taskId: string;
      type: "approved" | "rejected";
      createdAt: string;
      approvalId: string;
      summary: string;
    }
  | {
      taskId: string;
      type: "tool_started" | "tool_finished";
      createdAt: string;
      summary: string;
      detail?: string;
      payload?: unknown;
    }
  | {
      taskId: string;
      type: "screenshot";
      createdAt: string;
      imageBase64: string;
    }
  | {
      taskId: string;
      type: "completed";
      createdAt: string;
      result: BackendTaskResult;
    }
  | {
      taskId: string;
      type: "failed";
      createdAt: string;
      summary: string;
    }
  | {
      taskId: string;
      type: "cancelled";
      createdAt: string;
      summary: string;
    };

import type { AgentApp, AssistantLanguage, AutonomyMode, BrowserControlMode, CodexBridgeMode, VoiceInputMode, VoiceProvider } from "./samanthaConfig";

export interface MCPServerConfig {
  id: string;
  label: string;
  fullCommand: string;
  cwd?: string;
  enabled: boolean;
}

export interface ToolRegistryConfig {
  enableWebSearch: boolean;
  enableCodeInterpreter: boolean;
  enableImageGeneration: boolean;
  enableOpenClawBackend: boolean;
  vectorStoreIds: string[];
  mcpServers: MCPServerConfig[];
}

export interface CodexIntegrationConfig {
  enabled: boolean;
  godMode: boolean;
  mode: CodexBridgeMode;
  inboxPath: string;
  outboxPath: string;
  eventsPath: string;
  driveExpiresAt?: string;
}

export interface SettingsData {
  appName: string;
  apiKey: string;
  hasApiKey: boolean;
  voiceProvider: VoiceProvider;
  hasXaiApiKey: boolean;
  hasGeminiApiKey: boolean;
  grokVoice: string;
  geminiVoice: string;
  /** STT engine for the local provider: Apple dictation or the Parakeet server. */
  localSttEngine: "apple" | "parakeet";
  hotkey: string;
  voice: string;
  voiceInputMode: VoiceInputMode;
  language: AssistantLanguage;
  /** Seconds between proactive agent-monitor polls after a delegation. */
  monitorPollSeconds: number;
  /** Minutes before the proactive agent monitor stops polling. */
  monitorMaxMinutes: number;
  debugMode: boolean;
  autonomyMode: AutonomyMode;
  browserControlMode: BrowserControlMode;
  codexIntegration: CodexIntegrationConfig;
  toolRegistry: ToolRegistryConfig;
}

export interface PermissionSnapshot {
  microphone: PermissionStatus;
  screen: PermissionStatus;
  accessibilityTrusted: boolean;
  inputServerAvailable: boolean;
  inputServerVersion?: string;
  activeTaskIds?: string[];
}

export interface MemoryAuditRecord {
  id: string;
  memoryId: string;
  action: "save" | "delete";
  reason: string;
  createdAt: string;
  snapshot?: string;
}

export interface SettingsUpdate {
  apiKey?: string;
  voiceProvider?: VoiceProvider;
  xaiApiKey?: string;
  geminiApiKey?: string;
  grokVoice?: string;
  geminiVoice?: string;
  localSttEngine?: "apple" | "parakeet";
  hotkey?: string;
  voice?: string;
  voiceInputMode?: VoiceInputMode;
  language?: AssistantLanguage;
  monitorPollSeconds?: number;
  monitorMaxMinutes?: number;
  debugMode?: boolean;
  appName?: string;
  autonomyMode?: AutonomyMode;
  browserControlMode?: BrowserControlMode;
  codexIntegration?: Partial<CodexIntegrationConfig>;
  toolRegistry?: Partial<ToolRegistryConfig>;
}

export interface CodexBridgeEvent {
  id: string;
  type: "status" | "prepared" | "sent" | "blocked" | "stopped" | "read" | "summary" | "error";
  createdAt: string;
  summary: string;
  detail?: string;
  command?: string;
}

export interface CodexStatus {
  enabled: boolean;
  mode: CodexBridgeMode;
  codexRunning: boolean;
  codexPid?: number;
  queueDepth: number;
  heartbeatAt: string;
  inboxPath: string;
  outboxPath: string;
  eventsPath: string;
  driveExpiresAt?: string;
  lastEvent?: CodexBridgeEvent;
}

export interface CodexCommandRequest {
  /** Open a fresh conversation before typing. Default: continue the current chat. */
  newChat?: boolean;
  /** Press Enter after typing. Default: leave the brief unsent for user review. */
  autoSend?: boolean;
  intent: string;
  command: string;
  agent?: AgentApp;
  modeHint?: CodexBridgeMode;
  requireConfirmation?: boolean;
}

export interface CodexCommandResult {
  status: "observed" | "prepared" | "sent" | "blocked" | "stopped" | "error";
  summary: string;
  nextAction?: string;
  needsUserApproval: boolean;
  pmPrompt?: string;
  event?: CodexBridgeEvent;
}

export interface CodexReadResult {
  ok: boolean;
  running: boolean;
  text: string;
  capturedAt: string;
  error?: string;
}

export interface CodexPmStatus {
  ok: boolean;
  summary: string;
  codexRunning: boolean;
  needsUserAttention: boolean;
  currentState: "offline" | "idle" | "working" | "needs_user" | "unknown";
  lastReadableText?: string;
  lastEvent?: CodexBridgeEvent;
  capturedAt: string;
}

export interface BackendApprovalDecision {
  taskId: string;
  approvalId: string;
  approve: boolean;
  alwaysApply?: boolean;
  message?: string;
}

export interface RealtimeSnapshot {
  connected: boolean;
  muted: boolean;
  currentAgent: string;
  phase: TaskPhase;
}

export interface OverlayCommand {
  type: "show" | "hide" | "hotkey" | "open-onboarding";
}

export interface RealtimeClientSecret {
  value: string;
  expiresAt?: number;
}
