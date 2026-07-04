import { GoogleGenAI, Modality, type LiveServerMessage, type Session } from "@google/genai";

/// Gemini Live adapter exposing the same minimal surface the voice runtime
/// uses on RealtimeSession (sendAudio / sendMessage / interrupt / close), so
/// the rest of runtime.ts stays provider-agnostic. Image input is deliberately
/// unsupported here — see_screen is an OpenAI-only tool.

export interface GeminiToolDef {
  name: string;
  description: string;
  /** JSON-schema object as used by toolSchemas.ts strictObject helpers. */
  parameters: Record<string, unknown>;
  execute: (input: unknown) => Promise<unknown>;
}

export interface GeminiLiveCallbacks {
  onAudioChunk: (pcm: ArrayBuffer) => void;
  onAudioStart: () => void;
  onAudioStopped: () => void;
  onInterrupted: () => void;
  onToolStart: (name: string) => void;
  onToolEnd: (name: string) => void;
  onUserTranscript: (text: string) => void;
  onAssistantTranscript: (text: string) => void;
  onError: (message: string) => void;
  onClosed: (reason: string) => void;
  /** Latest session-resumption handle; pass it to the next connect to keep context. */
  onResumptionHandle?: (handle: string) => void;
}

export interface GeminiLiveConnectOptions {
  /** Ephemeral auth token minted by the sidecar (used in place of an API key). */
  token: string;
  model: string;
  voice: string;
  instructions: string;
  tools: GeminiToolDef[];
  callbacks: GeminiLiveCallbacks;
  /** Resume a previous session's context after a disconnect (15-min limit). */
  resumptionHandle?: string;
}

/** Gemini Live expects 16 kHz PCM input; the runtime captures at 24 kHz. */
const GEMINI_INPUT_RATE = 16_000;
const CAPTURE_RATE = 24_000;

function downsampleTo16k(pcm24k: ArrayBuffer): ArrayBuffer {
  const input = new Int16Array(pcm24k);
  const ratio = CAPTURE_RATE / GEMINI_INPUT_RATE;
  const outputLength = Math.floor(input.length / ratio);
  const output = new Int16Array(outputLength);
  for (let i = 0; i < outputLength; i++) {
    const position = i * ratio;
    const index = Math.floor(position);
    const fraction = position - index;
    const a = input[index] ?? 0;
    const b = input[index + 1] ?? a;
    output[i] = a + (b - a) * fraction;
  }
  return output.buffer;
}

function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

/** Strip JSON-schema keywords Gemini's function declarations don't accept. */
function sanitizeSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) {
    return schema.map(sanitizeSchema);
  }
  if (schema && typeof schema === "object") {
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(schema as Record<string, unknown>)) {
      if (key === "additionalProperties") {
        continue;
      }
      // Gemini rejects union types like ["string","null"]; use the non-null
      // member and rely on nullable.
      if (key === "type" && Array.isArray(value)) {
        const nonNull = value.filter((entry) => entry !== "null");
        result.type = nonNull[0] ?? "string";
        if (value.includes("null")) {
          result.nullable = true;
        }
        continue;
      }
      if (key === "enum" && Array.isArray(value)) {
        result.enum = value.filter((entry) => entry !== null);
        continue;
      }
      result[key] = sanitizeSchema(value);
    }
    return result;
  }
  return schema;
}

export class GeminiLiveVoiceSession {
  private constructor(
    private readonly session: Session,
    private readonly tools: Map<string, GeminiToolDef>,
    private readonly callbacks: GeminiLiveCallbacks
  ) {}

  private speaking = false;
  private closed = false;

  static async connect(options: GeminiLiveConnectOptions): Promise<GeminiLiveVoiceSession> {
    const client = new GoogleGenAI({
      apiKey: options.token,
      httpOptions: { apiVersion: "v1alpha" }
    });

    const toolMap = new Map(options.tools.map((tool) => [tool.name, tool]));
    let adapter: GeminiLiveVoiceSession | null = null;

    const session = await client.live.connect({
      model: options.model,
      config: {
        responseModalities: [Modality.AUDIO],
        systemInstruction: options.instructions,
        speechConfig: {
          voiceConfig: { prebuiltVoiceConfig: { voiceName: options.voice } }
        },
        tools: [
          {
            functionDeclarations: options.tools.map((tool) => ({
              name: tool.name,
              description: tool.description,
              parametersJsonSchema: sanitizeSchema(tool.parameters)
            }))
          }
        ],
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        // Extends the otherwise ~15-minute audio session limit.
        contextWindowCompression: { slidingWindow: {} },
        // Server sends resumption handles; reconnects keep the conversation.
        sessionResumption: options.resumptionHandle ? { handle: options.resumptionHandle } : {}
      },
      callbacks: {
        onmessage: (message: LiveServerMessage) => {
          adapter?.handleMessage(message);
        },
        onerror: (event) => {
          options.callbacks.onError(event.message || "Gemini Live connection error");
        },
        onclose: (event) => {
          if (adapter && !adapter.closed) {
            adapter.closed = true;
            options.callbacks.onClosed(event.reason || "Gemini Live session closed");
          }
        }
      }
    });

    adapter = new GeminiLiveVoiceSession(session, toolMap, options.callbacks);
    return adapter;
  }

  sendAudio(pcm24k: ArrayBuffer): void {
    if (this.closed) {
      return;
    }
    const pcm16k = downsampleTo16k(pcm24k);
    this.session.sendRealtimeInput({
      audio: {
        data: arrayBufferToBase64(pcm16k),
        mimeType: `audio/pcm;rate=${GEMINI_INPUT_RATE}`
      }
    });
  }

  sendMessage(text: string): void {
    if (this.closed) {
      return;
    }
    this.session.sendClientContent({
      turns: [{ role: "user", parts: [{ text }] }],
      turnComplete: true
    });
  }

  /** Signals end of the audio stream on push-to-talk turn commits. */
  commitAudioTurn(): void {
    if (this.closed) {
      return;
    }
    this.session.sendRealtimeInput({ audioStreamEnd: true });
  }

  /** Gemini handles barge-in server-side; locally we just mark playback state. */
  interrupt(): void {
    this.speaking = false;
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      this.session.close();
    } catch {
      // already closed by the server
    }
  }

  private handleMessage(message: LiveServerMessage): void {
    const newHandle = message.sessionResumptionUpdate?.newHandle;
    if (newHandle) {
      this.callbacks.onResumptionHandle?.(newHandle);
    }

    const content = message.serverContent;

    if (message.toolCall?.functionCalls?.length) {
      void this.runToolCalls(message.toolCall.functionCalls);
    }

    if (content?.interrupted) {
      this.speaking = false;
      this.callbacks.onInterrupted();
      return;
    }

    if (content?.inputTranscription?.text) {
      this.callbacks.onUserTranscript(content.inputTranscription.text);
    }
    if (content?.outputTranscription?.text) {
      this.callbacks.onAssistantTranscript(content.outputTranscription.text);
    }

    const parts = content?.modelTurn?.parts ?? [];
    for (const part of parts) {
      const data = part.inlineData?.data;
      if (typeof data === "string" && data.length > 0) {
        if (!this.speaking) {
          this.speaking = true;
          this.callbacks.onAudioStart();
        }
        this.callbacks.onAudioChunk(base64ToArrayBuffer(data));
      }
    }

    if (content?.turnComplete) {
      if (this.speaking) {
        this.speaking = false;
        this.callbacks.onAudioStopped();
      }
    }
  }

  private async runToolCalls(
    calls: Array<{ id?: string; name?: string; args?: Record<string, unknown> }>
  ): Promise<void> {
    for (const call of calls) {
      const name = call.name ?? "";
      const tool = this.tools.get(name);
      this.callbacks.onToolStart(name);
      let result: unknown;
      try {
        result = tool
          ? await tool.execute(call.args ?? {})
          : { ok: false, error: `Unknown tool '${name}'.` };
      } catch (error) {
        result = { ok: false, error: error instanceof Error ? error.message : String(error) };
      } finally {
        this.callbacks.onToolEnd(name);
      }
      if (this.closed) {
        return;
      }
      this.session.sendToolResponse({
        functionResponses: [
          {
            id: call.id,
            name,
            response: { result }
          }
        ]
      });
    }
  }
}
