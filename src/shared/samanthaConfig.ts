export const APP_DISPLAY_NAME = "Jarvis";
export const PLANNING_MODEL = "gpt-5.5";
export const REALTIME_MODEL = "gpt-realtime-2";
// "cedar" is the deepest, most natural-sounding male voice in the gpt-realtime
// lineup and handles Spanish natively — the closest match to the MCU Jarvis register.
export const DEFAULT_VOICE = "cedar";

// Voice providers. "openai" is the original stack; "grok" speaks the same
// Realtime protocol at wss://api.x.ai; "gemini" uses the Gemini Live API;
// "local" runs fully on-device (Apple STT/TTS + Ollama) and never reaches
// the WKWebView runtime — the Swift app drives it directly.
export type VoiceProvider = "openai" | "grok" | "gemini" | "local";
export const VOICE_PROVIDERS: VoiceProvider[] = ["openai", "grok", "gemini", "local"];
export const DEFAULT_VOICE_PROVIDER: VoiceProvider = "openai";

export const GROK_REALTIME_MODEL = "grok-voice-latest";
export const GROK_REALTIME_URL = `wss://api.x.ai/v1/realtime?model=${GROK_REALTIME_MODEL}`;
// "rex" (confident male) is the closest xAI match to the Jarvis register.
export const DEFAULT_GROK_VOICE = "rex";

export const GEMINI_LIVE_MODEL = "gemini-2.5-flash-native-audio-preview-12-2025";
// "Charon" is a deep male HD voice with native Spanish support.
export const DEFAULT_GEMINI_VOICE = "Charon";

// GUI agent apps Jarvis can drive (activate window → paste prompt → send).
export type AgentApp = "codex" | "claude";
export const AGENT_APPS: AgentApp[] = ["codex", "claude"];
export const DEFAULT_AGENT_APP: AgentApp = "codex";

export type AssistantLanguage = "es" | "en";
export type AutonomyMode = "maximum" | "safe" | "confirm_all";
export type BrowserControlMode = "headless" | "hybrid" | "gui" | "tool_first";
export type CodexBridgeMode = "observe" | "assist" | "drive";
export type VoiceInputMode = "push_to_talk" | "continuous" | "manual";

export const DEFAULT_AUTONOMY_MODE: AutonomyMode = "maximum";
export const DEFAULT_BROWSER_CONTROL_MODE: BrowserControlMode = "headless";
export const DEFAULT_CODEX_BRIDGE_MODE: CodexBridgeMode = "assist";
export const DEFAULT_ENABLE_OPENCLAW_BACKEND = false;
export const DEFAULT_VOICE_INPUT_MODE: VoiceInputMode = "push_to_talk";
export const DEFAULT_ASSISTANT_LANGUAGE: AssistantLanguage = "es";
