import fs from "node:fs";
import path from "node:path";
import { resolveApplicationSupportRoot } from "../../shared/appIdentity";
import { defaultSettings } from "../../shared/defaults";
import type { CodexIntegrationConfig, SettingsData, SettingsUpdate, ToolRegistryConfig } from "../../shared/types";

export class FileSettingsStore {
  private readonly settingsPath: string;
  private readonly secureEnvPath: string;
  private readonly xaiEnvPath: string;
  private readonly geminiEnvPath: string;

  constructor(private readonly rootDirectory = resolveApplicationSupportRoot()) {
    this.settingsPath = path.join(this.rootDirectory, "config", "settings.json");
    this.secureEnvPath =
      process.env.SAMANTHA_OPENAI_ENV_PATH ??
      path.join(this.rootDirectory, "secrets", "openai.env");
    this.xaiEnvPath = path.join(this.rootDirectory, "secrets", "xai.env");
    this.geminiEnvPath = path.join(this.rootDirectory, "secrets", "gemini.env");
    fs.mkdirSync(path.dirname(this.settingsPath), { recursive: true });
    if (!fs.existsSync(this.settingsPath)) {
      fs.writeFileSync(this.settingsPath, JSON.stringify(defaultSettings, null, 2));
    }

    const raw = this.readFile();
    const apiKey = raw.apiKey || this.readSecureApiKey() || process.env.OPENAI_API_KEY || "";
    if (apiKey) {
      process.env.OPENAI_API_KEY = apiKey;
    }
    if (raw.apiKey) {
      this.writeSecureApiKey(raw.apiKey);
      this.scrubSettingsApiKey();
    }
  }

  get dataDirectory(): string {
    return this.rootDirectory;
  }

  get(): SettingsData {
    const raw = this.readFile();
    const apiKey = raw.apiKey || this.readSecureApiKey() || process.env.OPENAI_API_KEY || "";
    const browserControlMode = raw.browserControlMode === "hybrid" ? "tool_first" : raw.browserControlMode;
    return {
      ...defaultSettings,
      ...raw,
      apiKey: "",
      hasApiKey: Boolean(apiKey),
      hasXaiApiKey: Boolean(this.getXaiApiKey()),
      hasGeminiApiKey: Boolean(this.getGeminiApiKey()),
      browserControlMode: browserControlMode ?? defaultSettings.browserControlMode,
      codexIntegration: {
        ...defaultSettings.codexIntegration,
        ...(raw.codexIntegration ?? {})
      },
      toolRegistry: {
        ...defaultSettings.toolRegistry,
        ...(raw.toolRegistry ?? {})
      }
    };
  }

  update(update: SettingsUpdate): SettingsData {
    const current = this.get();
    const { apiKey, xaiApiKey, geminiApiKey, ...settingsUpdate } = update;
    const trimmedApiKey = apiKey?.trim();
    if (trimmedApiKey) {
      this.writeSecureApiKey(trimmedApiKey);
      process.env.OPENAI_API_KEY = trimmedApiKey;
    }
    const trimmedXaiKey = xaiApiKey?.trim();
    if (trimmedXaiKey) {
      this.writeSecureEnv(this.xaiEnvPath, "XAI_API_KEY", trimmedXaiKey);
    }
    const trimmedGeminiKey = geminiApiKey?.trim();
    if (trimmedGeminiKey) {
      this.writeSecureEnv(this.geminiEnvPath, "GEMINI_API_KEY", trimmedGeminiKey);
    }

    const mergedToolRegistry: ToolRegistryConfig = {
      ...current.toolRegistry,
      ...(settingsUpdate.toolRegistry ?? {})
    };
    const mergedCodexIntegration: CodexIntegrationConfig = {
      ...current.codexIntegration,
      ...(settingsUpdate.codexIntegration ?? {})
    };
    const next: SettingsData = {
      ...current,
      ...settingsUpdate,
      apiKey: "",
      hasApiKey: Boolean(trimmedApiKey || this.readSecureApiKey() || process.env.OPENAI_API_KEY),
      hasXaiApiKey: Boolean(this.getXaiApiKey()),
      hasGeminiApiKey: Boolean(this.getGeminiApiKey()),
      codexIntegration: mergedCodexIntegration,
      toolRegistry: mergedToolRegistry
    };

    fs.writeFileSync(this.settingsPath, JSON.stringify(next, null, 2));
    return next;
  }

  getApiKey(): string {
    return this.readSecureApiKey() || process.env.OPENAI_API_KEY || "";
  }

  getXaiApiKey(): string {
    return this.readSecureEnv(this.xaiEnvPath, "XAI_API_KEY") || process.env.XAI_API_KEY || "";
  }

  getGeminiApiKey(): string {
    return this.readSecureEnv(this.geminiEnvPath, "GEMINI_API_KEY") || process.env.GEMINI_API_KEY || "";
  }

  private readFile(): Partial<SettingsData> {
    try {
      const raw = fs.readFileSync(this.settingsPath, "utf8");
      return JSON.parse(raw) as Partial<SettingsData>;
    } catch {
      return {};
    }
  }

  private readSecureApiKey(): string {
    return this.readSecureEnv(this.secureEnvPath, "OPENAI_API_KEY");
  }

  private writeSecureApiKey(apiKey: string): void {
    this.writeSecureEnv(this.secureEnvPath, "OPENAI_API_KEY", apiKey);
  }

  private readSecureEnv(envPath: string, variable: string): string {
    try {
      const raw = fs.readFileSync(envPath, "utf8");
      const match = raw.match(new RegExp(`^${variable}=(.*)$`, "m"));
      return match?.[1]?.trim() ?? "";
    } catch {
      return "";
    }
  }

  private writeSecureEnv(envPath: string, variable: string, value: string): void {
    fs.mkdirSync(path.dirname(envPath), { recursive: true, mode: 0o700 });
    fs.writeFileSync(envPath, `${variable}=${value}\n`, { mode: 0o600 });
    fs.chmodSync(envPath, 0o600);
  }

  private scrubSettingsApiKey(): void {
    const raw = this.readFile();
    if (!raw.apiKey) {
      return;
    }
    const { apiKey: _apiKey, ...safeRaw } = raw;
    fs.writeFileSync(this.settingsPath, JSON.stringify(safeRaw, null, 2));
  }
}
