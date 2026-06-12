export const APP_DISPLAY_NAME = "Jarvis";
export const PLANNING_MODEL = "gpt-5.5";
export const REALTIME_MODEL = "gpt-realtime-2";
// "cedar" is the deepest, most natural-sounding male voice in the gpt-realtime
// lineup and handles Spanish natively — the closest match to the MCU Jarvis register.
export const DEFAULT_VOICE = "cedar";

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
