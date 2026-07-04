import type { SettingsData } from "./types";
import {
  DEFAULT_ASSISTANT_LANGUAGE,
  APP_DISPLAY_NAME,
  DEFAULT_AUTONOMY_MODE,
  DEFAULT_BROWSER_CONTROL_MODE,
  DEFAULT_CODEX_BRIDGE_MODE,
  DEFAULT_ENABLE_OPENCLAW_BACKEND,
  DEFAULT_GEMINI_VOICE,
  DEFAULT_GROK_VOICE,
  DEFAULT_VOICE,
  DEFAULT_VOICE_INPUT_MODE,
  DEFAULT_VOICE_PROVIDER
} from "./samanthaConfig";

export const defaultSettings: SettingsData = {
  appName: APP_DISPLAY_NAME,
  apiKey: "",
  hasApiKey: false,
  voiceProvider: DEFAULT_VOICE_PROVIDER,
  hasXaiApiKey: false,
  hasGeminiApiKey: false,
  grokVoice: DEFAULT_GROK_VOICE,
  geminiVoice: DEFAULT_GEMINI_VOICE,
  localSttEngine: "apple",
  bargeInEnabled: true,
  hotkey: "Alt+Space",
  voice: DEFAULT_VOICE,
  voiceInputMode: DEFAULT_VOICE_INPUT_MODE,
  language: DEFAULT_ASSISTANT_LANGUAGE,
  monitorPollSeconds: 30,
  monitorMaxMinutes: 30,
  debugMode: false,
  autonomyMode: DEFAULT_AUTONOMY_MODE,
  browserControlMode: DEFAULT_BROWSER_CONTROL_MODE,
  codexIntegration: {
    enabled: true,
    godMode: false,
    mode: DEFAULT_CODEX_BRIDGE_MODE,
    inboxPath: "~/Library/Application Support/Jarvis/codex/inbox.md",
    outboxPath: "~/Library/Application Support/Jarvis/codex/outbox.md",
    eventsPath: "~/Library/Application Support/Jarvis/codex/events.jsonl"
  },
  toolRegistry: {
    enableWebSearch: true,
    enableCodeInterpreter: true,
    enableImageGeneration: true,
    enableOpenClawBackend: DEFAULT_ENABLE_OPENCLAW_BACKEND,
    vectorStoreIds: [],
    mcpServers: []
  }
};
