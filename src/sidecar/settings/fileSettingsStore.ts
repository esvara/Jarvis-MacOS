import fs from "node:fs";
import path from "node:path";
import { resolveApplicationSupportRoot } from "../../shared/appIdentity";
import { defaultSettings } from "../../shared/defaults";
import type { CodexIntegrationConfig, SettingsData, SettingsUpdate, ToolRegistryConfig } from "../../shared/types";

export class FileSettingsStore {
  private readonly settingsPath: string;
  private readonly secureEnvPath: string;

  constructor(private readonly rootDirectory = resolveApplicationSupportRoot()) {
    this.settingsPath = path.join(this.rootDirectory, "config", "settings.json");
    this.secureEnvPath =
      process.env.SAMANTHA_OPENAI_ENV_PATH ??
      path.join(this.rootDirectory, "secrets", "openai.env");
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
    const { apiKey, ...settingsUpdate } = update;
    const trimmedApiKey = apiKey?.trim();
    if (trimmedApiKey) {
      this.writeSecureApiKey(trimmedApiKey);
      process.env.OPENAI_API_KEY = trimmedApiKey;
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
      codexIntegration: mergedCodexIntegration,
      toolRegistry: mergedToolRegistry
    };

    fs.writeFileSync(this.settingsPath, JSON.stringify(next, null, 2));
    return next;
  }

  getApiKey(): string {
    return this.readSecureApiKey() || process.env.OPENAI_API_KEY || "";
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
    try {
      const raw = fs.readFileSync(this.secureEnvPath, "utf8");
      const match = raw.match(/^OPENAI_API_KEY=(.*)$/m);
      return match?.[1]?.trim() ?? "";
    } catch {
      return "";
    }
  }

  private writeSecureApiKey(apiKey: string): void {
    fs.mkdirSync(path.dirname(this.secureEnvPath), { recursive: true, mode: 0o700 });
    fs.writeFileSync(this.secureEnvPath, `OPENAI_API_KEY=${apiKey}\n`, { mode: 0o600 });
    fs.chmodSync(this.secureEnvPath, 0o600);
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
