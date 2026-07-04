import { APP_DISPLAY_NAME } from "../shared/samanthaConfig";
import type { CodexCommandResult, CodexPmStatus, MemoryRecord, MemorySaveInput } from "../shared/types";
import type { CodexBridge } from "./codexBridge";

/// v3 "local" voice provider: the Swift app does on-device STT/TTS and sends
/// each user turn here as text. This module runs the agent loop against a
/// local Ollama model with function calling, reusing the same delegation
/// bridge the cloud voice providers use. Nothing leaves the machine.

const OLLAMA_URL = process.env.JARVIS_OLLAMA_URL ?? "http://127.0.0.1:11434";
/// Measured on a MacBook Air M5 16 GB (2026-07-03): qwen3:4b-instruct answers
/// in ~1.5-3 s/turn using ~2.5 GB with solid tool calling; qwen3:8b is
/// smarter but needs ~6 GB and ~4-8 s/turn. Plain "qwen3:4b" is the THINKING
/// variant — 70+ s/turn with reasoning leaking into the reply; never use it.
const DEFAULT_LOCAL_MODEL = process.env.JARVIS_LOCAL_MODEL ?? "qwen3:4b-instruct";
const MAX_HISTORY_MESSAGES = 24;
const MAX_TOOL_ROUNDS = 4;

export interface LocalVoiceAgentDeps {
  codexBridge: CodexBridge;
  openUrl: (url?: string, searchQuery?: string) => Promise<{ ok: boolean; url?: string; error?: string }>;
  openFile: (path?: string, query?: string) => Promise<{ ok: boolean; path?: string; error?: string }>;
  readApp: (appName: string) => Promise<unknown>;
  searchMemory: (query: string) => MemoryRecord[];
  saveMemory: (input: MemorySaveInput) => { status: string; reason?: string };
}

interface OllamaMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  tool_calls?: Array<{ function: { name: string; arguments: Record<string, unknown> } }>;
}

interface OllamaChatResponse {
  message?: OllamaMessage;
  error?: string;
}

export interface LocalTurnResult {
  ok: boolean;
  reply: string;
  error?: string;
  /** Set when a delegation was delivered this turn, so the app can monitor it. */
  delegatedAgent?: "codex" | "claude";
}

const localTools = [
  {
    type: "function",
    function: {
      name: "delegate_to_agent",
      description:
        "Deliver a task brief to a local agent app (Codex or Claude) by pasting it into the app's chat box and sending it. Use for any real work: coding, writing, analysis.",
      parameters: {
        type: "object",
        properties: {
          agent: { type: "string", enum: ["codex", "claude"], description: "Target agent app; default codex." },
          prompt: { type: "string", description: "The brief, written naturally in the user's language." }
        },
        required: ["prompt"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "get_agent_status",
      description: "Read the agent app's window through Accessibility and summarize its progress, blockers, or needed approvals.",
      parameters: {
        type: "object",
        properties: {
          agent: { type: "string", enum: ["codex", "claude"], description: "Agent to check; default codex." }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "open_url",
      description: "Open a web page or a web search in the user's browser.",
      parameters: {
        type: "object",
        properties: {
          url: { type: "string", description: "Full URL to open." },
          searchQuery: { type: "string", description: "Search the web for this instead of a URL." }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "open_file",
      description:
        "Open and show the user a file with its default app. Give 'path' when known, otherwise 'query' (part of the file name) opens the most recently modified match.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "Absolute or ~/ path to the file." },
          query: { type: "string", description: "Part of the file name to search for." }
        },
        required: []
      }
    }
  },
  {
    type: "function",
    function: {
      name: "read_app",
      description: "Read the visible text of any running macOS app through Accessibility (window content, labels, messages).",
      parameters: {
        type: "object",
        properties: {
          appName: { type: "string", description: "App name, e.g. Safari, Notes, Codex." }
        },
        required: ["appName"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "search_memory",
      description: "Search the user's durable memories: preferences, environment facts, workflow defaults.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "What to look for." }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "save_memory",
      description: "Save a stable user preference or fact to durable memory. Only for information worth remembering across sessions.",
      parameters: {
        type: "object",
        properties: {
          subject: { type: "string", description: "Short title of the fact." },
          content: { type: "string", description: "The fact itself." }
        },
        required: ["subject", "content"]
      }
    }
  }
] as const;

function systemPrompt(language: string): string {
  const langLine =
    language === "en"
      ? "Reply in English unless the user speaks Spanish."
      : "Responde en español salvo que el usuario hable en inglés.";
  return `You are ${APP_DISPLAY_NAME}, a composed, precise voice assistant running fully locally. ${langLine}
Your replies are spoken aloud: keep them to one or two short sentences, no markdown, no lists.
You are a meta-controller for two local agent apps: "codex" (default) and "claude". You never do the work yourself — delegate real tasks with delegate_to_agent, check progress with get_agent_status, open web pages with open_url, open files with open_file, and read app windows with read_app.
A delegation only counts as delivered when the tool returns status "sent"; otherwise say exactly what failed. Never claim an agent finished without evidence from get_agent_status.
Use memory tools when the user shares stable preferences or asks what you remember.`;
}

export class LocalVoiceAgent {
  private history: OllamaMessage[] = [];
  private delegatedAgentThisTurn: "codex" | "claude" | undefined;

  constructor(private readonly deps: LocalVoiceAgentDeps) {}

  reset(): void {
    this.history = [];
  }

  /**
   * Runs one voice turn. When onDelta is provided, assistant text is
   * forwarded incrementally so the app can start speaking the first
   * sentence while the model is still generating.
   */
  async runTurn(
    userText: string,
    language: string,
    onDelta?: (delta: string) => void
  ): Promise<LocalTurnResult> {
    const messages: OllamaMessage[] = [
      { role: "system", content: systemPrompt(language) },
      ...this.history,
      { role: "user", content: userText }
    ];

    this.delegatedAgentThisTurn = undefined;
    let assistantReply = "";
    try {
      for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
        const message = onDelta ? await this.chatStreaming(messages, onDelta) : await this.chat(messages);
        if (message.tool_calls?.length && round < MAX_TOOL_ROUNDS) {
          messages.push(message);
          for (const call of message.tool_calls) {
            const result = await this.executeTool(call.function.name, call.function.arguments);
            messages.push({ role: "tool", content: JSON.stringify(result) });
          }
          continue;
        }
        assistantReply = message.content?.trim() ?? "";
        break;
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      const hint = /fetch failed|ECONNREFUSED/i.test(detail)
        ? language === "en"
          ? "Ollama is not running. Install it from ollama.com and run: ollama pull qwen3:4b-instruct"
          : "Ollama no está corriendo. Instálalo desde ollama.com y ejecuta: ollama pull qwen3:4b-instruct"
        : detail;
      return { ok: false, reply: "", error: hint };
    }

    if (!assistantReply) {
      assistantReply = language === "en" ? "Done." : "Listo.";
    }

    this.history.push({ role: "user", content: userText }, { role: "assistant", content: assistantReply });
    if (this.history.length > MAX_HISTORY_MESSAGES) {
      this.history = this.history.slice(-MAX_HISTORY_MESSAGES);
    }
    return { ok: true, reply: assistantReply, delegatedAgent: this.delegatedAgentThisTurn };
  }

  private async chat(messages: OllamaMessage[]): Promise<OllamaMessage> {
    const response = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: DEFAULT_LOCAL_MODEL,
        messages,
        tools: localTools,
        stream: false,
        // Hybrid-thinking models add seconds of latency per voice turn.
        think: false,
        options: { temperature: 0.4 }
      }),
      signal: AbortSignal.timeout(120_000)
    });
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new Error(`Ollama HTTP ${response.status}: ${body.slice(0, 200)}`);
    }
    const data = (await response.json()) as OllamaChatResponse;
    if (data.error) {
      throw new Error(data.error);
    }
    if (!data.message) {
      throw new Error("Ollama returned no message.");
    }
    return data.message;
  }

  /**
   * Streaming variant of chat(). Content deltas are forwarded as they
   * arrive; tool-call rounds normally produce no content, and any preamble
   * text the model emits before a tool call is fine to speak.
   */
  private async chatStreaming(
    messages: OllamaMessage[],
    onDelta: (delta: string) => void
  ): Promise<OllamaMessage> {
    const response = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: DEFAULT_LOCAL_MODEL,
        messages,
        tools: localTools,
        stream: true,
        think: false,
        options: { temperature: 0.4 }
      }),
      signal: AbortSignal.timeout(120_000)
    });
    if (!response.ok || !response.body) {
      const body = await response.text().catch(() => "");
      throw new Error(`Ollama HTTP ${response.status}: ${body.slice(0, 200)}`);
    }

    const merged: OllamaMessage = { role: "assistant", content: "" };
    const decoder = new TextDecoder();
    let buffered = "";
    const reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      buffered += decoder.decode(value, { stream: true });
      let newlineIndex = buffered.indexOf("\n");
      while (newlineIndex >= 0) {
        const line = buffered.slice(0, newlineIndex).trim();
        buffered = buffered.slice(newlineIndex + 1);
        newlineIndex = buffered.indexOf("\n");
        if (!line) {
          continue;
        }
        const chunk = JSON.parse(line) as OllamaChatResponse & { done?: boolean };
        if (chunk.error) {
          throw new Error(chunk.error);
        }
        const delta = chunk.message?.content ?? "";
        if (delta) {
          merged.content += delta;
          onDelta(delta);
        }
        if (chunk.message?.tool_calls?.length) {
          merged.tool_calls = [...(merged.tool_calls ?? []), ...chunk.message.tool_calls];
        }
      }
    }
    return merged;
  }

  private async executeTool(name: string, args: Record<string, unknown>): Promise<unknown> {
    try {
      if (name === "delegate_to_agent") {
        const prompt = typeof args.prompt === "string" ? args.prompt : "";
        const agent = args.agent === "claude" ? "claude" : "codex";
        if (!prompt.trim()) {
          return { ok: false, error: "prompt must not be empty" };
        }
        const result: CodexCommandResult = await this.deps.codexBridge.command({
          intent: prompt.slice(0, 80),
          command: prompt,
          agent
        });
        if (result.status === "sent") {
          this.delegatedAgentThisTurn = agent;
        }
        return result;
      }
      if (name === "get_agent_status") {
        const agent = args.agent === "claude" ? "claude" : "codex";
        const status: CodexPmStatus = await this.deps.codexBridge.pmStatus(undefined, agent, true);
        return status;
      }
      if (name === "open_url") {
        return await this.deps.openUrl(
          typeof args.url === "string" ? args.url : undefined,
          typeof args.searchQuery === "string" ? args.searchQuery : undefined
        );
      }
      if (name === "open_file") {
        return await this.deps.openFile(
          typeof args.path === "string" ? args.path : undefined,
          typeof args.query === "string" ? args.query : undefined
        );
      }
      if (name === "read_app") {
        const appName = typeof args.appName === "string" ? args.appName.trim() : "";
        if (!appName) {
          return { ok: false, error: "appName must not be empty" };
        }
        return await this.deps.readApp(appName);
      }
      if (name === "search_memory") {
        const query = typeof args.query === "string" ? args.query : "";
        const memories = this.deps.searchMemory(query).slice(0, 6);
        return { count: memories.length, memories };
      }
      if (name === "save_memory") {
        const subject = typeof args.subject === "string" ? args.subject : "";
        const content = typeof args.content === "string" ? args.content : "";
        if (subject.length < 3 || content.length < 3) {
          return { ok: false, error: "subject and content are required" };
        }
        return this.deps.saveMemory({
          kind: "preference",
          subject,
          content,
          confidence: 0.8,
          source: "local voice",
          tags: []
        });
      }
      return { ok: false, error: `Unknown tool '${name}'.` };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }
}
