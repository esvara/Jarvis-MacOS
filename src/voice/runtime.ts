import { tool } from "@openai/agents";
import {
  RealtimeAgent,
  RealtimeSession,
  OpenAIRealtimeWebSocket,
  type RealtimeClientMessage,
  type RealtimeItem,
  type RealtimeSessionEventTypes
} from "@openai/agents/realtime";
import type {
  SettingsData,
  TranscriptEntry
} from "../shared/types";
import {
  codexCommandToolParameters,
  codexStatusToolParameters,
  pasteIntoAppToolParameters,
  parsePasteIntoAppToolInput,
  clickInAppToolParameters,
  parseClickInAppToolInput,
  openFileToolParameters,
  parseOpenFileToolInput,
  forgetMemoryToolParameters,
  parseCodexCommandToolInput,
  parseCodexStatusToolInput,
  parseForgetMemoryToolInput,
  parseSaveMemoryToolInput,
  parseSearchMemoryToolInput,
  parseStartBackendTaskToolInput,
  saveMemoryToolParameters,
  searchMemoryToolParameters,
  startBackendTaskToolParameters
} from "../shared/toolSchemas";
import { APP_DISPLAY_NAME, REALTIME_MODEL } from "../shared/samanthaConfig";

type RealtimeApprovalRequest = RealtimeSessionEventTypes["tool_approval_requested"][2];

type VoiceApprovalRequest = {
  id: string;
  title: string;
  detail?: string;
  request: RealtimeApprovalRequest;
};

type VoicePhase =
  | "idle"
  | "connecting"
  | "listening"
  | "thinking"
  | "speaking"
  | "acting"
  | "approvals"
  | "error";

type Command =
  | { type: "connect"; muted?: boolean }
  | { type: "close" }
  | { type: "interrupt" }
  | { type: "setMuted"; muted: boolean }
  | { type: "approveApproval"; alwaysApprove?: boolean }
  | { type: "rejectApproval"; message?: string; alwaysReject?: boolean };

type SettingsPatch = {
  apiKey?: string;
};

type MemoryRecord = {
  id: string;
  kind: string;
  subject: string;
  content: string;
};

type MemoryPolicyResult = {
  decision: "allow" | "approval_required" | "block";
  reason: string;
  normalizedTags: string[];
};

type BackendTaskResult = {
  taskId: string;
  summary: string;
  outputText: string;
  agent: string;
  completedAt: string;
};

type CodexCommandResult = {
  status: "observed" | "prepared" | "sent" | "blocked" | "stopped" | "error";
  summary: string;
  nextAction?: string;
  needsUserApproval: boolean;
  pmPrompt?: string;
};

type CodexPmStatus = {
  ok: boolean;
  summary: string;
  codexRunning: boolean;
  needsUserAttention: boolean;
  currentState: "offline" | "idle" | "working" | "needs_user" | "unknown";
  lastReadableText?: string;
  capturedAt: string;
};

type MemorySaveResponse = {
  status: "saved" | "saved_after_approval" | "blocked";
  reason: string;
  memory?: MemoryRecord;
};

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        jarveyVoice?: {
          postMessage: (payload: unknown) => void;
        };
      };
    };
    __JARVEY_AUTH_TOKEN__?: string;
    jarveyVoiceBridge?: {
      receive: (command: Command) => Promise<unknown>;
    };
  }
}

const SIDECAR_BASE =
  (globalThis as { __JARVEY_SIDECAR_BASE__?: string }).__JARVEY_SIDECAR_BASE__ ??
  "http://127.0.0.1:4818";

const SAMPLE_RATE = 24000;

let session: RealtimeSession | null = null;
let connectPromise: Promise<void> | null = null;
let activeApproval: VoiceApprovalRequest["request"] | null = null;
let phase: VoicePhase = "idle";
let currentAgent = "ConversationAgent";
let connected = false;
let muted = false;
let transcriptHistory: TranscriptEntry[] = [];
let level = 0;
const timestampCache = new Map<string, string>();
let levelSmoothed = 0;
let outputLevelSmoothed = 0;
let outputLevelUpdatedAt = 0;

// Audio I/O state
let micStream: MediaStream | null = null;
let inputAudioContext: AudioContext | null = null;
let inputProcessor: ScriptProcessorNode | null = null;
let inputAnalyser: AnalyserNode | null = null;
let inputAnalyserData: Uint8Array<ArrayBuffer> | null = null;
let levelIntervalId: number | null = null;
let playbackContext: AudioContext | null = null;
let playbackNextTime = 0;
const activePlaybackSources = new Set<AudioBufferSourceNode>();
let speechDetectedSinceUnmute = false;

async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  message: string
): Promise<T> {
  return await Promise.race([
    promise,
    new Promise<T>((_resolve, reject) => {
      window.setTimeout(() => {
        reject(new Error(message));
      }, timeoutMs);
    })
  ]);
}

function extractErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === "object" && error !== null) {
    const obj = error as Record<string, unknown>;
    // API error: { type: "error", error: { type, message, code, param } }
    if (typeof obj.error === "object" && obj.error !== null) {
      const inner = obj.error as Record<string, unknown>;
      if (typeof inner.message === "string") {
        return inner.message;
      }
      // Double-nested: transport wraps API events
      if (typeof inner.error === "object" && inner.error !== null) {
        const deep = inner.error as Record<string, unknown>;
        if (typeof deep.message === "string") {
          return deep.message;
        }
      }
    }
    if (typeof obj.message === "string") {
      return obj.message;
    }
  }
  if (typeof error === "string") {
    return error;
  }
  try {
    return JSON.stringify(error).slice(0, 300);
  } catch {
    return "Realtime session failed.";
  }
}

function postMessage(type: string, payload?: Record<string, unknown>) {
  window.webkit?.messageHandlers?.jarveyVoice?.postMessage({
    type,
    ...(payload ?? {})
  });
}

function postRuntimeError(message: string) {
  postMessage("error", { message });
}

function postState() {
  postMessage("state", {
    connected,
    muted,
    phase,
    currentAgent,
    level
  });
}

function setPhase(nextPhase: VoicePhase) {
  phase = nextPhase;
  postState();
}

function setConnected(nextConnected: boolean) {
  connected = nextConnected;
  postState();
}

function setMuted(nextMuted: boolean) {
  muted = nextMuted;
  if (muted) {
    setLevel(0);
  } else {
    speechDetectedSinceUnmute = false;
  }
  postState();
}

function setAgent(nextAgent: string) {
  currentAgent = nextAgent;
  postState();
}

function setLevel(nextLevel: number) {
  const normalized = Math.max(0, Math.min(1, Number.isFinite(nextLevel) ? nextLevel : 0));
  if (Math.abs(normalized - level) < 0.015) {
    return;
  }
  level = normalized;
  postState();
}

// Floors keep a subtle idle pulse per phase; they stay low so the visible
// wave tracks the real audio envelope (mic RMS or assistant speech RMS)
// instead of pinning at a constant height.
function phaseFloor(currentPhase: VoicePhase): number {
  switch (currentPhase) {
    case "connecting":
      return 0.12;
    case "thinking":
      return 0.14;
    case "speaking":
      return 0.08;
    case "acting":
      return 0.14;
    case "approvals":
      return 0.1;
    default:
      return 0;
  }
}

function languageDirective(language: string | undefined): string {
  if (language === "en") {
    return "DEFAULT LANGUAGE: English. Always speak and respond in English unless the user explicitly asks you to switch languages.";
  }
  return "IDIOMA POR DEFECTO: Español. Habla y responde siempre en español (de México/neutral) a menos que el usuario te pida explícitamente cambiar de idioma.";
}

async function requestJson<T>(
  path: string,
  init?: RequestInit
): Promise<T> {
  const headers = new Headers(init?.headers);
  headers.set("Content-Type", headers.get("Content-Type") ?? "application/json");
  if (window.__JARVEY_AUTH_TOKEN__ && !headers.has("Authorization")) {
    headers.set("Authorization", `Bearer ${window.__JARVEY_AUTH_TOKEN__}`);
  }

  const response = await fetch(`${SIDECAR_BASE}${path}`, {
    ...init,
    headers
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `Request failed for ${path} (${response.status})`);
  }

  return (await response.json()) as T;
}

function itemText(item: RealtimeItem): string {
  if (item.type !== "message") {
    return "";
  }

  return item.content
    .map((contentPart) => {
      if ("text" in contentPart && typeof contentPart.text === "string") {
        return contentPart.text;
      }
      if ("transcript" in contentPart && contentPart.transcript) {
        return contentPart.transcript;
      }
      return "";
    })
    .join(" ")
    .trim();
}

function buildTranscriptHistory(history: RealtimeItem[]): TranscriptEntry[] {
  return history
    .filter((item): item is Extract<RealtimeItem, { type: "message" }> => item.type === "message")
    .map((item) => {
      const timestamp = timestampCache.get(item.itemId) ?? new Date().toISOString();
      timestampCache.set(item.itemId, timestamp);
      const role: TranscriptEntry["role"] =
        item.role === "assistant"
          ? "assistant"
          : item.role === "user"
            ? "user"
            : "system";
      return {
        id: item.itemId,
        role,
        text: itemText(item),
        timestamp
      };
    })
    .filter((entry) => entry.text.length > 0);
}

function approvalSummary(
  approval: VoiceApprovalRequest["request"]
): { title: string; detail?: string } {
  if (approval.type === "function_approval") {
    const rawItem = approval.approvalItem.rawItem;
    return {
      title: `Approve ${approval.tool?.name ?? "tool"}`,
      detail: "arguments" in rawItem ? rawItem.arguments : undefined
    };
  }

  return {
    title: "Approve MCP tool call",
    detail: approval.approvalItem.arguments
  };
}

function emitTranscript(entries: TranscriptEntry[]) {
  transcriptHistory = entries;
  postMessage("transcript", {
    entries
  });
}

function emitRealtimeApproval(approval: VoiceApprovalRequest | null) {
  postMessage("realtimeApproval", {
    approval: approval
      ? {
          id: approval.id,
          title: approval.title,
          detail: approval.detail
        }
      : null
  });
}

async function fetchSettings(): Promise<SettingsData> {
  return await requestJson<SettingsData>("/settings");
}

// ---------------------------------------------------------------------------
// Audio helpers - manual I/O for WebSocket transport
// ---------------------------------------------------------------------------

function float32ToPcm16(float32: Float32Array): ArrayBuffer {
  const pcm16 = new Int16Array(float32.length);
  for (let i = 0; i < float32.length; i++) {
    const sample = Math.max(-1, Math.min(1, float32[i]));
    pcm16[i] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
  }
  return pcm16.buffer;
}

function float32Rms(float32: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < float32.length; i++) {
    const sample = float32[i];
    sum += sample * sample;
  }
  return Math.sqrt(sum / float32.length);
}

function pcm16ToFloat32(pcm16: ArrayBuffer): Float32Array {
  const int16 = new Int16Array(pcm16);
  const float32 = new Float32Array(int16.length);
  for (let i = 0; i < int16.length; i++) {
    float32[i] = int16[i] / (int16[i] < 0 ? 0x8000 : 0x7fff);
  }
  return float32;
}

function playAudioChunk(float32: Float32Array) {
  if (!playbackContext) {
    return;
  }
  if (playbackContext.state === "suspended") {
    void playbackContext.resume().catch(() => undefined);
  }

  const outputRms = float32Rms(float32);
  outputLevelSmoothed = Math.max(outputRms * 4.2, outputLevelSmoothed * 0.86);
  outputLevelUpdatedAt = performance.now();
  setLevel(Math.max(outputLevelSmoothed, levelSmoothed, phaseFloor(phase)));

  const buffer = playbackContext.createBuffer(1, float32.length, SAMPLE_RATE);
  buffer.getChannelData(0).set(float32);
  const source = playbackContext.createBufferSource();
  source.buffer = buffer;
  source.connect(playbackContext.destination);
  activePlaybackSources.add(source);
  source.onended = () => {
    activePlaybackSources.delete(source);
  };

  const now = playbackContext.currentTime;
  if (playbackNextTime < now) {
    playbackNextTime = now;
  }
  source.start(playbackNextTime);
  playbackNextTime += buffer.duration;
}

/** Stop every scheduled output buffer immediately (barge-in / Stop button). */
function flushPlayback() {
  for (const source of activePlaybackSources) {
    try {
      source.onended = null;
      source.stop();
    } catch {
      // already stopped
    }
  }
  activePlaybackSources.clear();
  playbackNextTime = 0;
  outputLevelSmoothed = 0;
}

// ---------------------------------------------------------------------------
// Proactive agent monitoring: after a brief is delivered, poll the agent and
// have Jarvis narrate completion, blockers, or needed approvals.
// ---------------------------------------------------------------------------

const MONITOR_POLL_MS = 30_000;
const MONITOR_MAX_MS = 30 * 60_000;
let monitorTimerId: number | null = null;
let monitorAgent: "codex" | "claude" | null = null;
let monitorStartedAt = 0;
let monitorLastState = "";
let monitorSawWorking = false;

function agentDisplayName(agent: string): string {
  return agent === "codex" ? "Codex" : "Claude";
}

function stopAgentMonitor() {
  if (monitorTimerId !== null) {
    window.clearInterval(monitorTimerId);
    monitorTimerId = null;
  }
  monitorAgent = null;
  monitorLastState = "";
  monitorSawWorking = false;
}

/** Returns false when the session is busy and the narration must be retried. */
function narrateMonitorUpdate(text: string): boolean {
  if (!session) {
    return false;
  }
  // Don't talk over the user or an in-flight exchange; the next poll retries.
  if (phase === "speaking" || phase === "thinking" || phase === "acting" || phase === "approvals") {
    return false;
  }
  session.sendMessage(
    `[Monitor automático de agentes — no es el usuario] ${text} Informa al usuario en una sola frase breve y natural.`
  );
  return true;
}

function startAgentMonitor(agent: "codex" | "claude") {
  stopAgentMonitor();
  monitorAgent = agent;
  monitorStartedAt = performance.now();

  monitorTimerId = window.setInterval(() => {
    void (async () => {
      if (!session || !monitorAgent) {
        stopAgentMonitor();
        return;
      }
      if (performance.now() - monitorStartedAt > MONITOR_MAX_MS) {
        stopAgentMonitor();
        return;
      }
      let status: CodexPmStatus;
      try {
        status = await requestJson<CodexPmStatus>("/codex/pm-status", {
          method: "POST",
          body: JSON.stringify({ agent: monitorAgent, quiet: true })
        });
      } catch {
        return;
      }
      const name = agentDisplayName(monitorAgent);
      const state = status.currentState;
      if (state === "working") {
        monitorSawWorking = true;
      }
      if (state === monitorLastState) {
        return;
      }

      if (state === "needs_user") {
        if (narrateMonitorUpdate(`${name} necesita una aprobación o interacción del usuario. Resumen: ${status.summary}`)) {
          stopAgentMonitor();
        }
        return;
      }
      if (state === "offline") {
        if (narrateMonitorUpdate(`${name} dejó de estar disponible (la app parece cerrada).`)) {
          stopAgentMonitor();
        }
        return;
      }
      if (state === "idle" && monitorSawWorking) {
        if (narrateMonitorUpdate(`${name} parece haber terminado la tarea delegada. Resumen de su ventana: ${status.summary}`)) {
          stopAgentMonitor();
        }
        return;
      }
      monitorLastState = state;
    })();
  }, MONITOR_POLL_MS);
}

async function startAudioIO() {
  playbackContext = new AudioContext({ sampleRate: SAMPLE_RATE });
  // WebKit creates AudioContexts suspended when there is no user gesture;
  // without an explicit resume the scheduled buffers never reach the speakers.
  await playbackContext.resume().catch(() => undefined);
  playbackNextTime = 0;

  if (session) {
    session.transport.on("audio", (event: { data: ArrayBuffer }) => {
      const float32 = pcm16ToFloat32(event.data);
      playAudioChunk(float32);
    });
  }

  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error("Microphone capture is not available in this WebView.");
  }

  try {
    micStream = await withTimeout(
      navigator.mediaDevices.getUserMedia({
        audio: {
          sampleRate: SAMPLE_RATE,
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true
        }
      }),
      15_000,
      "Timed out waiting for microphone access. Check macOS Microphone permission for Samantha and make sure no system prompt is waiting behind another window."
    );
  } catch (error) {
    const message = extractErrorMessage(error);
    throw new Error(`Microphone unavailable: ${message}`);
  }

  inputAudioContext = new AudioContext({ sampleRate: SAMPLE_RATE });
  await inputAudioContext.resume().catch(() => undefined);
  const source = inputAudioContext.createMediaStreamSource(micStream);

  inputAnalyser = inputAudioContext.createAnalyser();
  inputAnalyser.fftSize = 256;
  source.connect(inputAnalyser);
  inputAnalyserData = new Uint8Array(new ArrayBuffer(inputAnalyser.frequencyBinCount));

  inputProcessor = inputAudioContext.createScriptProcessor(4096, 1, 1);
  source.connect(inputProcessor);
  inputProcessor.connect(inputAudioContext.destination);
  inputProcessor.onaudioprocess = (event) => {
    if (!session || muted || phase === "speaking") {
      return;
    }

    const float32 = event.inputBuffer.getChannelData(0);
    const rms = float32Rms(float32);
    if (rms > 0.018) {
      speechDetectedSinceUnmute = true;
      if (phase === "idle") {
        setPhase("listening");
      }
    }

    const pcmBuffer = float32ToPcm16(float32);
    session.sendAudio(pcmBuffer);
  };

  levelIntervalId = window.setInterval(() => {
    // Mic energy only counts while unmuted; assistant speech energy always
    // counts, so the wave stays in sync with whichever side is talking.
    if (inputAnalyser && inputAnalyserData && !muted) {
      inputAnalyser.getByteTimeDomainData(inputAnalyserData);
      let sum = 0;
      for (const value of inputAnalyserData) {
        const centered = (value - 128) / 128;
        sum += centered * centered;
      }
      const rms = Math.sqrt(sum / inputAnalyserData.length);
      levelSmoothed = Math.max(rms * 3.6, levelSmoothed * 0.78);
    } else {
      levelSmoothed *= 0.78;
    }

    const outputAge = performance.now() - outputLevelUpdatedAt;
    outputLevelSmoothed = outputAge < 320 ? outputLevelSmoothed * 0.94 : outputLevelSmoothed * 0.76;
    const composite = Math.max(levelSmoothed, outputLevelSmoothed, phaseFloor(phase));
    setLevel(composite);
  }, 80);
}

async function stopAudioIO() {
  if (levelIntervalId !== null) {
    window.clearInterval(levelIntervalId);
    levelIntervalId = null;
  }

  if (inputProcessor) {
    inputProcessor.onaudioprocess = null;
    inputProcessor.disconnect();
    inputProcessor = null;
  }

  inputAnalyser = null;
  inputAnalyserData = null;

  if (micStream) {
    for (const track of micStream.getTracks()) {
      track.stop();
    }
    micStream = null;
  }

  if (inputAudioContext) {
    await inputAudioContext.close().catch(() => undefined);
    inputAudioContext = null;
  }

  if (playbackContext) {
    await playbackContext.close().catch(() => undefined);
    playbackContext = null;
  }

  playbackNextTime = 0;
  levelSmoothed = 0;
  outputLevelSmoothed = 0;
  outputLevelUpdatedAt = 0;
  speechDetectedSinceUnmute = false;
  setLevel(0);
}

// ---------------------------------------------------------------------------
// Session event wiring
// ---------------------------------------------------------------------------

function attachSession(nextSession: RealtimeSession) {
  nextSession.on("history_updated", (history) => {
    emitTranscript(buildTranscriptHistory(history));
  });

  nextSession.on("agent_start", (_context, agent) => {
    setAgent(agent.name);
    speechDetectedSinceUnmute = false;
    setPhase("thinking");
  });

  nextSession.on("agent_end", (_context, agent) => {
    setAgent(agent.name);
    if (phase !== "speaking" && phase !== "acting") {
      setPhase("idle");
    }
  });

  nextSession.on("agent_handoff", (_context, _fromAgent, toAgent) => {
    setAgent(toAgent.name);
    setPhase("thinking");
  });

  nextSession.on("agent_tool_start", (_context, _agent, toolDef) => {
    setPhase(toolDef.name === "start_backend_task" ? "acting" : "thinking");
  });

  nextSession.on("agent_tool_end", (_context, _agent, toolDef) => {
    setPhase(toolDef.name === "start_backend_task" ? "speaking" : "listening");
  });

  nextSession.on("audio_start", () => {
    outputLevelSmoothed = Math.max(outputLevelSmoothed, 0.36);
    outputLevelUpdatedAt = performance.now();
    setPhase("speaking");
  });

  nextSession.on("audio_stopped", () => {
    outputLevelSmoothed = 0;
    setPhase("idle");
  });

  nextSession.on("audio_interrupted", () => {
    setPhase("listening");
    flushPlayback();
  });

  nextSession.on("tool_approval_requested", (_context, _agent, approvalRequest) => {
    activeApproval = approvalRequest;
    const summary = approvalSummary(approvalRequest);
    const approval: VoiceApprovalRequest = {
      id:
        approvalRequest.approvalItem.rawItem.id ??
        ("callId" in approvalRequest.approvalItem.rawItem
          ? approvalRequest.approvalItem.rawItem.callId
          : undefined) ??
        crypto.randomUUID(),
      title: summary.title,
      detail: summary.detail,
      request: approvalRequest
    };
    emitRealtimeApproval(approval);
    setPhase("approvals");
  });

  nextSession.on("error", ({ error }) => {
    const message = extractErrorMessage(error);
    postRuntimeError(message);
  });
}

// ---------------------------------------------------------------------------
// Connect / disconnect
// ---------------------------------------------------------------------------

async function connect(initialMuted = false) {
  if (session) {
    return;
  }

  if (connectPromise) {
    return await connectPromise;
  }

  connectPromise = (async () => {
    const currentSettings = await fetchSettings();
    if (!currentSettings.hasApiKey) {
      throw new Error("OpenAI API key is not configured.");
    }
    const godModeEnabled = currentSettings.codexIntegration?.godMode === true;

    setPhase("connecting");

    const searchMemoryTool = tool({
      name: "search_memory",
      description:
        "Search durable memories such as preferences, environment facts, aliases, safe macros, and workflow defaults.",
      parameters: searchMemoryToolParameters,
      execute: async (input) => {
        const normalizedInput = parseSearchMemoryToolInput(input);
        const memories = await requestJson<MemoryRecord[]>("/memory/search", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        return {
          count: memories.length,
          memories
        };
      }
    });

    const saveMemoryTool = tool({
      name: "save_memory",
      description:
        "Save stable preferences, aliases, environment facts, workflow defaults, or safe macros into durable memory. Never store secrets or raw captured content.",
      parameters: saveMemoryToolParameters,
      needsApproval: async (_runContext, input) => {
        const normalizedInput = parseSaveMemoryToolInput(input);
        const policy = await requestJson<MemoryPolicyResult>("/memory/classify", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        return policy.decision === "approval_required";
      },
      execute: async (input) => {
        const normalizedInput = parseSaveMemoryToolInput(input);
        const result = await requestJson<MemorySaveResponse>("/memory/save", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        if (result.memory) {
          postMessage("memoryChanged");
        }
        return result;
      }
    });

    const forgetMemoryTool = tool({
      name: "forget_memory",
      description:
        "Delete a durable memory when the user explicitly asks you to forget or correct something.",
      parameters: forgetMemoryToolParameters,
      needsApproval: true,
      execute: async (input) => {
        const normalizedInput = parseForgetMemoryToolInput(input);
        const deleted = await requestJson<MemoryRecord[]>("/memory/forget", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        postMessage("memoryChanged");
        return {
          deletedCount: deleted.length,
          deleted
        };
      }
    });

    const startBackendTaskTool = tool({
      name: "start_backend_task",
      description:
        "Invoke the backend supervisor when the user wants the computer to do real work such as GUI automation, coding, patching files, or combined tasks.",
      parameters: startBackendTaskToolParameters,
      execute: async (input) => {
        const { request, activeAppHint } = parseStartBackendTaskToolInput(input);
        setPhase("acting");
        const recentMemories = await requestJson<MemoryRecord[]>("/memory/recent?limit=6");
        const taskId = crypto.randomUUID();
        postMessage("taskState", {
          taskId
        });
        const result = await requestJson<BackendTaskResult>("/backend/tasks/run", {
          method: "POST",
          body: JSON.stringify({
            requestId: taskId,
            userRequest: request,
            transcriptHistory,
            activeAppHint,
            memoryContext: recentMemories
              .slice(0, 6)
              .map((memory) => `[${memory.kind}] ${memory.subject}: ${memory.content}`)
              .join("\n")
          })
        });
        postMessage("taskState", {
          taskId: null
        });
        setPhase("speaking");
        return {
          taskId: result.taskId,
          summary: result.summary,
          agent: result.agent
        };
      }
    });

    const delegateToAgentTool = tool({
      name: "delegate_to_agent",
      description:
        "Deliver an execution brief to one of the local agent apps (Codex or Claude) by pasting it into the app's prompt box and sending it. Interpret the user's intent, craft a concise high-quality brief, and pick the agent the user named — default to Codex when unspecified.",
      parameters: codexCommandToolParameters,
      execute: async (input) => {
        const normalizedInput = parseCodexCommandToolInput(input);
        setPhase("acting");
        const result = await requestJson<CodexCommandResult>("/codex/command", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        setPhase("speaking");
        if (result.status === "sent") {
          startAgentMonitor(normalizedInput.agent ?? "codex");
        }
        return result;
      }
    });

    const getAgentStatusTool = tool({
      name: "get_agent_status",
      description:
        "Read the chosen agent app (Codex or Claude) through Accessibility and summarize its current status, progress, blockers, or needed user approval.",
      parameters: codexStatusToolParameters,
      execute: async (input) => {
        const normalizedInput = parseCodexStatusToolInput(input);
        setPhase("thinking");
        const result = await requestJson<CodexPmStatus>("/codex/pm-status", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        setPhase("speaking");
        return result;
      }
    });

    const pasteIntoAppTool = tool({
      name: "paste_text_into_app",
      description:
        "Open (or activate) any macOS app by name — e.g. Notes, Word, PowerPoint, TextEdit — and paste the given text into its focused text field. Set submit=true only when the text should also be sent with Enter (chat-style apps).",
      parameters: pasteIntoAppToolParameters,
      execute: async (input) => {
        const normalizedInput = parsePasteIntoAppToolInput(input);
        setPhase("acting");
        const result = await requestJson<{ ok: boolean; verified?: boolean; error?: string }>("/app/paste", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        setPhase("speaking");
        return result;
      }
    });

    const clickInAppTool = tool({
      name: "click_in_app",
      description:
        "Click a button, link, or menu item in a running macOS app by its visible label (case-insensitive, partial match). Use it to press things like 'Open in', 'Abrir', 'Download' or 'Guardar' in Codex, Claude, or any other app the user names.",
      parameters: clickInAppToolParameters,
      execute: async (input) => {
        const normalizedInput = parseClickInAppToolInput(input);
        setPhase("acting");
        const result = await requestJson<{ ok: boolean; clicked?: string; error?: string }>("/app/click", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        setPhase("speaking");
        return result;
      }
    });

    const openFileTool = tool({
      name: "open_file",
      description:
        "Open a file on the Mac and show it to the user with its default app (PDF in Preview, .docx in Word, etc.), or with a specific app via appName. Give 'path' when you know it; otherwise give 'query' (part of the file name) and the most recently modified match is opened. Returns the opened path.",
      parameters: openFileToolParameters,
      execute: async (input) => {
        const normalizedInput = parseOpenFileToolInput(input);
        setPhase("acting");
        const result = await requestJson<{ ok: boolean; path?: string; error?: string }>("/files/open", {
          method: "POST",
          body: JSON.stringify(normalizedInput)
        });
        setPhase("speaking");
        return result;
      }
    });

    const conversationAgent = new RealtimeAgent({
      name: "ConversationAgent",
      voice: currentSettings.voice,
      handoffDescription: "Voice front door: conversation, memory, and delegation to agent apps.",
      instructions: `
You are ${APP_DISPLAY_NAME}, a composed, precise, voice-first assistant in the spirit of J.A.R.V.I.S. from the Marvel films: unflappable, dryly witty when appropriate, always efficient and respectful. Keep answers brief and natural for speech.
${languageDirective(currentSettings.language)}

YOUR ROLE — you are a meta-controller for two local agent apps. You never operate the computer yourself; all real work is delegated:
- "codex" — OpenAI Codex app. The DEFAULT agent when the user does not name one.
- "claude" — Anthropic Claude app.

HOW TO DELEGATE:
1. Listen to the user's request and infer the real goal. Ask only what is essential.
2. Pick the agent: if the user names one ("dile a Claude...", "que Codex haga..."), use that one; otherwise use codex.
3. Briefly acknowledge out loud what you are about to delegate and to whom.
4. Call delegate_to_agent with the chosen agent and a clean, natural prompt in the user's language saying exactly what the user asked for — plus only the context or constraints the user actually gave. The text lands verbatim in the agent's chat box and the user reads it, so NO template sections, NO headings like "Entregable", "Definition of Done" or "Execution guidance", NO response-format requirements. Write it like a well-phrased message a person would type. Never paste a raw transcript.
5. The bridge activates the app's window, pastes the brief into its prompt box, and sends it.

MONITORING:
- After you deliver a brief, an automatic monitor polls that agent every 30 seconds for up to 30 minutes. When it detects completion, a blocker, or a needed approval, you receive a message tagged "[Monitor automático de agentes]" — it comes from the system, NOT from the user. Relay it in one short natural sentence (e.g. "Señor, Codex terminó la tarea." / "Claude necesita una aprobación.").
- Use get_agent_status (with the same agent) when the user asks how it is going, whether it finished, what changed, or whether something is blocked.
- Summarize like a project manager: current goal, progress, evidence, blockers, next action. Never read long output verbatim and never expose secrets.
- Never claim an agent finished without evidence from get_agent_status or a tool result.

SAFETY:
- For sensitive or irreversible requests (credentials, payments, external sends or publishing, mass deletion, destructive or privileged commands), confirm with the user before delegating.
- If the bridge returns needsUserApproval or blocked, explain plainly what is needed.

LIGHT APP ACTIONS:
- With paste_text_into_app you can open any macOS app by name and paste text into it (Notes, Word, PowerPoint, TextEdit, etc.). Use it when the user asks to put text somewhere, dictate a note, or drop content into a document. Use submit=true only for chat-style apps where Enter sends.
- With open_file you can open and SHOW the user any file (PDF, Word, Markdown, images...). When an agent finishes and produced files, offer to open them; if the user says "ábrelo" / "muéstramelo", call open_file with a query taken from the file name the agent mentioned. Tell the user what you opened.
- With click_in_app you can press a visible button, link, or menu item by its label in a running app — e.g. "Open in" on a Codex output card, "Abrir", "Download". Use the label the user said or the one visible in the agent's result. If it fails, say which label you tried.
- That is your only direct computer action; anything more complex must be delegated to an agent app.

HONEST REPORTING:
- A delegation only counts as delivered when the tool returns status "sent". If it returns "blocked" or an error, tell the user exactly what failed and what is needed — never say you sent it.

Use memory tools when the user shares stable preferences or defaults. Do not claim you personally clicked or typed — the agent apps do the work; you direct them and report back.
`,
      handoffs: [],
      tools: [searchMemoryTool, saveMemoryTool, forgetMemoryTool, delegateToAgentTool, getAgentStatusTool, pasteIntoAppTool, clickInAppTool, openFileTool]
    });

    const clientSecret = await requestJson<{ value: string }>("/realtime/client-secret", {
      method: "POST",
      body: JSON.stringify({} as SettingsPatch)
    });
    if (!clientSecret.value) {
      throw new Error("Realtime client secret is missing.");
    }

    const transport = new OpenAIRealtimeWebSocket({
      useInsecureApiKey: true
    });

    const nextSession = new RealtimeSession(conversationAgent, {
      transport,
      model: REALTIME_MODEL,
      config: {
        outputModalities: ["audio"],
        audio: {
          input: {
            format: {
              type: "audio/pcm",
              rate: SAMPLE_RATE
            }
          },
          output: {
            format: {
              type: "audio/pcm",
              rate: SAMPLE_RATE
            },
            voice: currentSettings.voice
          }
        }
      }
    });

    attachSession(nextSession);
    session = nextSession;
    await startAudioIO();
    await nextSession.connect({
      apiKey: clientSecret.value,
      model: REALTIME_MODEL
    });

    setConnected(true);
    setMuted(initialMuted);
    setPhase(initialMuted ? "idle" : "listening");
  })()
    .catch(async (error) => {
      const message = extractErrorMessage(error);
      postRuntimeError(message);
      await close();
      throw error;
    })
    .finally(() => {
      connectPromise = null;
    });

  return await connectPromise;
}

async function close() {
  stopAgentMonitor();
  await stopAudioIO();
  session?.close();
  session = null;
  activeApproval = null;
  speechDetectedSinceUnmute = false;
  emitRealtimeApproval(null);
  setConnected(false);
  setMuted(true);
  setPhase("idle");
}

function interrupt() {
  session?.interrupt();
  flushPlayback();
  setPhase(muted ? "idle" : "listening");
}

function setSessionMuted(nextMuted: boolean): boolean {
  const wasListening = connected && phase === "listening" && !muted;
  const shouldCommitTurn = nextMuted && wasListening && speechDetectedSinceUnmute;
  setMuted(nextMuted);
  if (!connected) {
    setPhase("idle");
    return muted;
  }
  if (shouldCommitTurn && session) {
    const commitEvent: RealtimeClientMessage = {
      type: "input_audio_buffer.commit"
    };
    session.transport.sendEvent(commitEvent);
    setPhase("thinking");
  } else if (nextMuted && wasListening) {
    setPhase("idle");
  } else if (!nextMuted && (phase === "idle" || phase === "connecting")) {
    setPhase("listening");
  } else if (nextMuted && phase === "listening") {
    setPhase("idle");
  }
  return muted;
}

async function approveApproval(alwaysApprove = false) {
  if (!session || !activeApproval) {
    return;
  }

  await session.approve(activeApproval.approvalItem, { alwaysApprove });
  activeApproval = null;
  emitRealtimeApproval(null);
  setPhase("thinking");
}

async function rejectApproval(message?: string, alwaysReject = false) {
  if (!session || !activeApproval) {
    return;
  }

  await session.reject(activeApproval.approvalItem, {
    alwaysReject,
    message
  });
  activeApproval = null;
  emitRealtimeApproval(null);
  setPhase("thinking");
}

window.jarveyVoiceBridge = {
  async receive(command: Command) {
    switch (command.type) {
      case "connect":
        await connect(command.muted ?? false);
        return null;
      case "close":
        await close();
        return null;
      case "interrupt":
        interrupt();
        return null;
      case "setMuted":
        return setSessionMuted(command.muted);
      case "approveApproval":
        await approveApproval(command.alwaysApprove ?? false);
        return null;
      case "rejectApproval":
        await rejectApproval(command.message, command.alwaysReject ?? false);
        return null;
      default:
        return null;
    }
  }
};

window.addEventListener("beforeunload", () => {
  void close();
});

window.addEventListener("error", (event) => {
  postRuntimeError(event.message || "A JavaScript error occurred in the voice runtime.");
});

window.addEventListener("unhandledrejection", (event) => {
  postRuntimeError(extractErrorMessage(event.reason));
});

postMessage("ready");
postState();
