import { APP_DISPLAY_NAME } from "../shared/samanthaConfig";
import type { CodexCommandResult, CodexPmStatus } from "../shared/types";
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

interface OllamaMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  tool_calls?: Array<{ function: { name: string; arguments: Record<string, unknown> } }>;
}

interface OllamaChatResponse {
  message?: OllamaMessage;
  error?: string;
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
  }
] as const;

function systemPrompt(language: string): string {
  const langLine =
    language === "en"
      ? "Reply in English unless the user speaks Spanish."
      : "Responde en español salvo que el usuario hable en inglés.";
  return `You are ${APP_DISPLAY_NAME}, a composed, precise voice assistant running fully locally. ${langLine}
Your replies are spoken aloud: keep them to one or two short sentences, no markdown, no lists.
You are a meta-controller for two local agent apps: "codex" (default) and "claude". You never do the work yourself — delegate real tasks with delegate_to_agent, check progress with get_agent_status, and open web pages with open_url.
A delegation only counts as delivered when the tool returns status "sent"; otherwise say exactly what failed. Never claim an agent finished without evidence from get_agent_status.`;
}

export class LocalVoiceAgent {
  private history: OllamaMessage[] = [];

  constructor(
    private readonly codexBridge: CodexBridge,
    private readonly openUrl: (url?: string, searchQuery?: string) => Promise<{ ok: boolean; url?: string; error?: string }>
  ) {}

  reset(): void {
    this.history = [];
  }

  async runTurn(userText: string, language: string): Promise<{ ok: boolean; reply: string; error?: string }> {
    const messages: OllamaMessage[] = [
      { role: "system", content: systemPrompt(language) },
      ...this.history,
      { role: "user", content: userText }
    ];

    let assistantReply = "";
    try {
      for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
        const message = await this.chat(messages);
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
    return { ok: true, reply: assistantReply };
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
        // Qwen3's thinking mode adds seconds of latency per voice turn.
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

  private async executeTool(name: string, args: Record<string, unknown>): Promise<unknown> {
    try {
      if (name === "delegate_to_agent") {
        const prompt = typeof args.prompt === "string" ? args.prompt : "";
        const agent = args.agent === "claude" ? "claude" : "codex";
        if (!prompt.trim()) {
          return { ok: false, error: "prompt must not be empty" };
        }
        const result: CodexCommandResult = await this.codexBridge.command({
          intent: prompt.slice(0, 80),
          command: prompt,
          agent
        });
        return result;
      }
      if (name === "get_agent_status") {
        const agent = args.agent === "claude" ? "claude" : "codex";
        const status: CodexPmStatus = await this.codexBridge.pmStatus(undefined, agent, true);
        return status;
      }
      if (name === "open_url") {
        return await this.openUrl(
          typeof args.url === "string" ? args.url : undefined,
          typeof args.searchQuery === "string" ? args.searchQuery : undefined
        );
      }
      return { ok: false, error: `Unknown tool '${name}'.` };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }
}
