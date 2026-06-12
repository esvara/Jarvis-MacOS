import fs from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  createClickAction,
  createDoubleClickAction,
  createDragAction,
  createKeyAction,
  createMoveAction,
  createScrollAction,
  createTypeAction,
  type GPTMouseButton,
  type NativeInputAction
} from "./computerControlLayer";
import { resolveAppLogsDirectory } from "../../../shared/appIdentity";

const LOG_FILE = path.join(resolveAppLogsDirectory(), "computer-control.log");

function controlLog(level: string, msg: string, data?: unknown) {
  let line = `${new Date().toISOString()} [${level}] ${msg}`;
  if (data !== undefined) {
    try {
      line += ` ${JSON.stringify(data)}`;
    } catch {
      line += " [unserializable]";
    }
  }
  fs.appendFile(LOG_FILE, line + "\n").catch(() => {
    // best-effort
  });
}

const execFileAsync = promisify(execFile);

export interface DisplayInfo {
  width: number;
  height: number;
}

const INPUT_SERVER_BASE_URL = "http://127.0.0.1:4819";
const INPUT_SERVER_URL = `${INPUT_SERVER_BASE_URL}/action`;
const INPUT_SERVER_SCREENSHOT_URL = `${INPUT_SERVER_BASE_URL}/screenshot`;
const INPUT_SERVER_EMERGENCY_STOP_URL = `${INPUT_SERVER_BASE_URL}/emergency-stop`;
const INPUT_SERVER_RESUME_ACTIONS_URL = `${INPUT_SERVER_BASE_URL}/resume-actions`;
const INPUT_SERVER_AGENT_STATUS_URL = `${INPUT_SERVER_BASE_URL}/agent/status`;
const INPUT_SERVER_AGENT_READ_URL = `${INPUT_SERVER_BASE_URL}/agent/read`;
const INPUT_SERVER_AGENT_SEND_PROMPT_URL = `${INPUT_SERVER_BASE_URL}/agent/send-prompt`;
const INPUT_SERVER_APP_PASTE_URL = `${INPUT_SERVER_BASE_URL}/app/paste`;
const INPUT_SERVER_APP_CLICK_URL = `${INPUT_SERVER_BASE_URL}/app/click`;

function authHeaders(): HeadersInit {
  const token = process.env.JARVEY_AUTH_TOKEN;
  return token ? { Authorization: `Bearer ${token}` } : {};
}

// POST a JSON action to JarveyNative's input action server.
// JarveyNative has Accessibility permission and posts CGEvents from its own process.
// Actions are normalized before dispatch so the native side receives a strict schema.
async function sendInputAction(action: NativeInputAction): Promise<void> {
  const res = await fetch(INPUT_SERVER_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(action),
    signal: AbortSignal.timeout(10_000)
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Input action server returned ${res.status}: ${text}`);
  }
  const json = (await res.json().catch(() => ({}))) as { ok?: boolean; error?: string };
  if (json.ok === false) {
    throw new Error(`Input action failed: ${json.error ?? "unknown"}`);
  }
}

export class NativeComputerBridge {
  private static displayCache:
    | { expiresAt: number; value: DisplayInfo }
    | null = null;
  private static readonly screenPermissionError =
    "Screen Recording permission is required. Grant access in Privacy & Security > Screen Recording.";

  /** Check if JarveyNative's InputActionServer is reachable. */
  async healthCheck(): Promise<{
    available: boolean;
    version?: string;
    accessibilityTrusted?: boolean;
    screen?: string;
    actionsBlocked?: boolean;
  }> {
    try {
      const res = await fetch(INPUT_SERVER_URL.replace("/action", "/health"), {
        signal: AbortSignal.timeout(3_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        trusted?: boolean;
        accessibilityTrusted?: boolean;
        screen?: string;
        actionsBlocked?: boolean;
      };
      if (res.ok) {
        return {
          available: true,
          version: "native",
          accessibilityTrusted: json.accessibilityTrusted ?? json.trusted,
          screen: json.screen,
          actionsBlocked: json.actionsBlocked
        };
      }
      // Server responded but not OK - still reachable
      return {
        available: true,
        version: "native",
        accessibilityTrusted: json.accessibilityTrusted ?? json.trusted,
        screen: json.screen,
        actionsBlocked: json.actionsBlocked
      };
    } catch {
      return { available: false };
    }
  }

  async getPrimaryDisplay(): Promise<DisplayInfo> {
    const cached = NativeComputerBridge.displayCache;
    if (cached && cached.expiresAt > Date.now()) {
      return cached.value;
    }

    const fallback: DisplayInfo = { width: 1440, height: 900 };
    let info = fallback;
    try {
      const result = await execFileAsync(
        "/usr/sbin/system_profiler",
        ["SPDisplaysDataType", "-json"],
        { timeout: 10_000 }
      );
      const parsed = JSON.parse(result.stdout);
      const displays = parsed?.SPDisplaysDataType;
      if (Array.isArray(displays)) {
        outer: for (const gpu of displays) {
          const screens = gpu?.spdisplays_ndrvs;
          if (Array.isArray(screens)) {
            for (const screen of screens) {
              const res = screen._spdisplays_resolution;
              if (typeof res === "string") {
                const match = res.match(/(\d+)\s*x\s*(\d+)/);
                if (match) {
                  info = { width: Number(match[1]), height: Number(match[2]) };
                  break outer;
                }
              }
            }
          }
        }
      }
    } catch {
      // use fallback
    }
    NativeComputerBridge.displayCache = { expiresAt: Date.now() + 60_000, value: info };
    return info;
  }

  async emergencyStop(): Promise<void> {
    await this.sendControlRequest(INPUT_SERVER_EMERGENCY_STOP_URL, "emergency stop");
  }

  async resumeActions(): Promise<void> {
    await this.sendControlRequest(INPUT_SERVER_RESUME_ACTIONS_URL, "resume actions");
  }

  async agentStatus(app = "codex"): Promise<{ running: boolean; installed?: boolean; pid?: number; name?: string }> {
    try {
      const res = await fetch(`${INPUT_SERVER_AGENT_STATUS_URL}?app=${encodeURIComponent(app)}`, {
        headers: authHeaders(),
        signal: AbortSignal.timeout(3_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        running?: boolean;
        installed?: boolean;
        pid?: number;
        name?: string;
      };
      return {
        running: res.ok && json.ok !== false && json.running === true,
        installed: json.installed,
        pid: json.pid,
        name: json.name
      };
    } catch {
      return { running: false };
    }
  }

  async sendAgentPrompt(
    prompt: string,
    app = "codex"
  ): Promise<{ ok: boolean; verified?: boolean; handoff?: boolean; error?: string }> {
    try {
      const res = await fetch(INPUT_SERVER_AGENT_SEND_PROMPT_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ prompt, app }),
        signal: AbortSignal.timeout(45_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        verified?: boolean;
        handoff?: boolean;
        error?: string;
      };
      if (!res.ok || json.ok === false) {
        return {
          ok: false,
          error: json.error ?? `Agent native bridge returned ${res.status}`
        };
      }
      return { ok: true, verified: json.verified, handoff: json.handoff };
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : String(error)
      };
    }
  }

  async pasteIntoApp(
    appName: string,
    text: string,
    submit = false
  ): Promise<{ ok: boolean; verified?: boolean; error?: string }> {
    try {
      const res = await fetch(INPUT_SERVER_APP_PASTE_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ app: appName, text, submit }),
        signal: AbortSignal.timeout(30_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        verified?: boolean;
        error?: string;
      };
      if (!res.ok || json.ok === false) {
        return { ok: false, error: json.error ?? `App paste bridge returned ${res.status}` };
      }
      return { ok: true, verified: json.verified };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  async clickInApp(
    appName: string,
    label: string
  ): Promise<{ ok: boolean; clicked?: string; error?: string }> {
    try {
      const res = await fetch(INPUT_SERVER_APP_CLICK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...authHeaders() },
        body: JSON.stringify({ app: appName, label }),
        signal: AbortSignal.timeout(30_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        clicked?: string;
        error?: string;
      };
      if (!res.ok || json.ok === false) {
        return { ok: false, error: json.error ?? `App click bridge returned ${res.status}` };
      }
      return { ok: true, clicked: json.clicked };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  async readAgent(app = "codex"): Promise<{ ok: boolean; running: boolean; text: string; capturedAt: string; error?: string }> {
    try {
      const res = await fetch(`${INPUT_SERVER_AGENT_READ_URL}?app=${encodeURIComponent(app)}`, {
        headers: authHeaders(),
        signal: AbortSignal.timeout(6_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        running?: boolean;
        text?: string;
        capturedAt?: string;
        error?: string;
      };
      return {
        ok: res.ok && json.ok !== false,
        running: json.running === true,
        text: typeof json.text === "string" ? json.text : "",
        capturedAt: json.capturedAt ?? new Date().toISOString(),
        error: json.error
      };
    } catch (error) {
      return {
        ok: false,
        running: false,
        text: "",
        capturedAt: new Date().toISOString(),
        error: error instanceof Error ? error.message : String(error)
      };
    }
  }

  private async sendControlRequest(url: string, label: string): Promise<void> {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: authHeaders(),
        signal: AbortSignal.timeout(3_000)
      });
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        controlLog("WARN", `${label} returned ${res.status}: ${text}`);
      }
    } catch (error) {
      controlLog("WARN", `${label} failed`, { error: error instanceof Error ? error.message : String(error) });
    }
  }

  async screenshot(): Promise<string> {
    controlLog("INFO", "screenshot -> native input server");
    try {
      const inputServer = await this.healthCheck();
      controlLog("INFO", "screenshot health", inputServer);
      if (!inputServer.available) {
        throw new Error("Input action server is unavailable.");
      }
      if (inputServer.screen !== "granted") {
        throw new Error(NativeComputerBridge.screenPermissionError);
      }

      const res = await fetch(INPUT_SERVER_SCREENSHOT_URL, {
        headers: authHeaders(),
        signal: AbortSignal.timeout(20_000)
      });
      const json = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        error?: string;
        data?: string;
      };
      if (!res.ok || json.ok === false || typeof json.data !== "string") {
        throw new Error(json.error ?? `Input action server returned ${res.status}`);
      }

      controlLog("INFO", `screenshot captured: ${json.data.length} base64 chars`);
      return json.data;
    } catch (error) {
      const failure = error as {
        stderr?: string;
        stdout?: string;
        code?: number;
        message?: string;
      };
      const detail = failure.stderr?.trim() || failure.stdout?.trim() || failure.message || String(error);
      controlLog("ERROR", `screenshot failed: ${detail}`, { code: failure.code });
      throw new Error(`Screenshot failed: ${detail}`);
    }
  }

  // All input actions go through JarveyNative's InputActionServer.

  async click(x: number, y: number, button: GPTMouseButton): Promise<void> {
    controlLog("INFO", `action: click (${x}, ${y}) ${button}`);
    await sendInputAction(createClickAction(x, y, button));
  }

  async doubleClick(x: number, y: number, button: GPTMouseButton = "left"): Promise<void> {
    controlLog("INFO", `action: double_click (${x}, ${y}) ${button}`);
    await sendInputAction(createDoubleClickAction(x, y, button));
  }

  async move(x: number, y: number): Promise<void> {
    controlLog("INFO", `action: move (${x}, ${y})`);
    await sendInputAction(createMoveAction(x, y));
  }

  async scroll(x: number, y: number, scrollX: number, scrollY: number): Promise<void> {
    controlLog("INFO", `action: scroll (${x}, ${y}) dx=${scrollX} dy=${scrollY}`);
    await sendInputAction(createScrollAction(x, y, scrollX, scrollY));
  }

  async type(text: string): Promise<void> {
    controlLog("INFO", `action: type ${text.length} chars`);
    await sendInputAction(createTypeAction(text));
  }

  async keypress(keys: string[]): Promise<void> {
    const action = createKeyAction(keys);
    if (action.type === "keypress") {
      controlLog("INFO", `action: keypress [${action.keys.join(", ")}]`);
    } else {
      controlLog("INFO", `action: hotkey ${action.combo}`);
    }
    await sendInputAction(action);
  }

  async drag(pathPoints: [number, number][]): Promise<void> {
    const action = createDragAction(pathPoints);
    const from = action.path[0];
    const to = action.path[action.path.length - 1];
    controlLog("INFO", `action: drag (${from.x},${from.y}) -> (${to.x},${to.y})`);
    await sendInputAction(action);
  }
}
