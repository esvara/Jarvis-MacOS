import fs from "node:fs/promises";
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import pathModule from "node:path";
import { URL } from "node:url";
import { nanoid } from "nanoid";
import { BackendRuntime } from "../main/backend/backendRuntime";
import { evaluateMemoryWrite } from "../main/backend/memory/policy";
import { NativeComputerBridge } from "../main/backend/tools/nativeComputerBridge";
import type {
  BackendApprovalDecision,
  BackendTaskEvent,
  BackendTaskInput,
  CodexCommandRequest,
  MemoryForgetInput,
  MemorySaveInput,
  MemorySearchInput,
  SettingsUpdate
} from "../shared/types";
import { createRealtimeClientSecret } from "./createRealtimeClientSecret";
import { CodexBridge } from "./codexBridge";
import { logger } from "./logger";
import { FileSettingsStore } from "./settings/fileSettingsStore";

const HOST = "127.0.0.1";
const DEFAULT_PORT = 4818;

function parseFlagValue(flagName: string): string | undefined {
  const flagIndex = process.argv.findIndex((value) => value === flagName);
  const raw = flagIndex >= 0 ? process.argv[flagIndex + 1] : undefined;
  if (!raw) {
    return undefined;
  }
  const trimmed = raw.trim();
  return trimmed.length ? trimmed : undefined;
}

function parsePort(): number {
  const portFlagIndex = process.argv.findIndex((value) => value === "--port");
  if (portFlagIndex >= 0) {
    const raw = process.argv[portFlagIndex + 1];
    const parsed = Number.parseInt(raw ?? "", 10);
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
  }

  const fromEnv = Number.parseInt(process.env.JARVEY_PORT ?? "", 10);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }

  return DEFAULT_PORT;
}

function parseAssetsRoot(): string {
  return parseFlagValue("--assets-root") ?? process.env.JARVEY_ASSETS_ROOT ?? process.cwd();
}

function parseWorkingDirectory(): string {
  return (
    parseFlagValue("--working-directory") ??
    process.env.JARVEY_WORKING_DIRECTORY ??
    process.env.HOME ??
    process.cwd()
  );
}

function parseAuthToken(): string {
  return parseFlagValue("--auth-token") ?? process.env.JARVEY_AUTH_TOKEN ?? "";
}

function localResponseHeaders(contentType?: string): Record<string, string> {
  return {
    ...(contentType ? { "Content-Type": contentType } : {}),
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": `http://${HOST}:${parsePort()}`,
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS"
  };
}

function isAuthorized(request: IncomingMessage, authToken: string): boolean {
  if (!authToken) {
    return false;
  }
  return request.headers.authorization === `Bearer ${authToken}`;
}

function isPublicRoute(method: string, pathname: string): boolean {
  return method === "GET" && (pathname === "/health" || pathname === "/voice-runtime.js");
}

async function readJson<T>(request: IncomingMessage): Promise<T> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  if (!chunks.length) {
    return {} as T;
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as T;
}

/// Open a file for the user with its default app (or a named one). When no
/// path is given, find the best match by name via Spotlight: most recently
/// modified file whose name contains the query.
async function openFileForUser(
  filePath?: string,
  query?: string,
  appName?: string
): Promise<{ ok: boolean; path?: string; error?: string }> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const run = promisify(execFile);

  let resolved = filePath?.trim();
  if (resolved?.startsWith("~/")) {
    resolved = pathModule.join(process.env.HOME ?? "", resolved.slice(2));
  }

  if (resolved) {
    try {
      await fs.access(resolved);
    } catch {
      return { ok: false, error: `No existe el archivo '${resolved}'.` };
    }
  } else {
    const trimmedQuery = query?.trim();
    if (!trimmedQuery) {
      return { ok: false, error: "Provide 'path' or 'query'." };
    }
    let candidates: string[] = [];
    try {
      const { stdout } = await run(
        "/usr/bin/mdfind",
        ["-onlyin", process.env.HOME ?? "/", `kMDItemFSName == "*${trimmedQuery}*"cd`],
        { timeout: 10_000, maxBuffer: 4 * 1024 * 1024 }
      );
      candidates = stdout.split("\n").filter(Boolean);
    } catch {
      candidates = [];
    }
    const stats = await Promise.all(
      candidates.slice(0, 200).map(async (candidate) => {
        try {
          const stat = await fs.stat(candidate);
          return stat.isFile() ? { candidate, mtime: stat.mtimeMs } : null;
        } catch {
          return null;
        }
      })
    );
    const newest = stats
      .filter((entry): entry is { candidate: string; mtime: number } => entry !== null)
      .sort((a, b) => b.mtime - a.mtime)[0];
    if (!newest) {
      return { ok: false, error: `No encontré ningún archivo que coincida con '${trimmedQuery}'.` };
    }
    resolved = newest.candidate;
  }

  const args = appName?.trim() ? ["-a", appName.trim(), resolved] : [resolved];
  try {
    await run("/usr/bin/open", args, { timeout: 15_000 });
    return { ok: true, path: resolved };
  } catch (error) {
    return {
      ok: false,
      path: resolved,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

function sendJson(response: ServerResponse, statusCode: number, payload: unknown): void {
  response.writeHead(statusCode, localResponseHeaders("application/json; charset=utf-8"));
  response.end(JSON.stringify(payload));
}

function sendText(response: ServerResponse, statusCode: number, payload: string): void {
  response.writeHead(statusCode, localResponseHeaders("text/plain; charset=utf-8"));
  response.end(payload);
}

function sendHtml(response: ServerResponse, statusCode: number, payload: string): void {
  response.writeHead(statusCode, localResponseHeaders("text/html; charset=utf-8"));
  response.end(payload);
}

function eventFrame(eventName: string, payload: unknown): string {
  return `event: ${eventName}\ndata: ${JSON.stringify(payload)}\n\n`;
}

function eventSummary(event: BackendTaskEvent): string | undefined {
  switch (event.type) {
    case "started":
    case "delegated":
    case "approved":
    case "rejected":
    case "tool_started":
    case "tool_finished":
    case "failed":
    case "cancelled":
      return event.summary;
    case "approval_requested":
      return event.approval.summary;
    case "completed":
      return event.result.summary;
    case "screenshot":
      return "Screenshot captured.";
  }
}

async function sendFile(
  response: ServerResponse,
  filePath: string,
  contentType: string
): Promise<void> {
  const body = await fs.readFile(filePath, "utf8");
  response.writeHead(200, localResponseHeaders(contentType));
  response.end(body);
}

async function main() {
  logger.rotate();
  logger.info("Sidecar starting", { pid: process.pid, argv: process.argv });

  const assetsRoot = parseAssetsRoot();
  const workingDirectory = parseWorkingDirectory();
  const authToken = parseAuthToken();
  if (!authToken) {
    logger.warn("Sidecar started without JARVEY_AUTH_TOKEN; sensitive endpoints will reject requests.");
  }
  const settingsStore = new FileSettingsStore();
  const backendRuntime = new BackendRuntime(
    settingsStore,
    workingDirectory,
    settingsStore.dataDirectory
  );
  const inputBridge = new NativeComputerBridge();
  const codexBridge = new CodexBridge(settingsStore, inputBridge);
  const sseClients = new Set<ServerResponse>();
  const backendEventHistory: BackendTaskEvent[] = [];

  backendRuntime.on("event", (event: BackendTaskEvent) => {
    logger.info(`backend:${event.type}`, {
      taskId: event.taskId,
      summary: eventSummary(event)
    });
    backendEventHistory.unshift(event);
    if (backendEventHistory.length > 400) {
      backendEventHistory.length = 400;
    }
    for (const client of sseClients) {
      client.write(eventFrame("backend", event));
    }
  });

  const server = http.createServer(async (request, response) => {
    const method = request.method ?? "GET";
    const url = new URL(request.url ?? "/", `http://${HOST}:${parsePort()}`);
    const pathname = url.pathname;

    try {
      logger.info(`${method} ${pathname}`);

      if (method === "OPTIONS") {
        response.writeHead(204, localResponseHeaders());
        response.end();
        return;
      }

      if (!isPublicRoute(method, pathname) && !isAuthorized(request, authToken)) {
        sendJson(response, authToken ? 401 : 503, {
          error: authToken ? "Unauthorized" : "Local auth token is not configured."
        });
        return;
      }

      if (method === "GET" && pathname === "/health") {
        const inputServer = await inputBridge.healthCheck();
        sendJson(response, 200, {
          ok: true,
          pid: process.pid,
          inputServerAvailable: inputServer.available,
          inputServerVersion: inputServer.version,
          hasApiKey: Boolean(settingsStore.getApiKey()),
          secured: Boolean(authToken),
          activeTaskIds: backendRuntime.activeTaskIds()
        });
        return;
      }

      if (method === "GET" && pathname === "/logs") {
        const logName = url.searchParams.get("name") ?? "sidecar";
        const tail = Number.parseInt(url.searchParams.get("tail") ?? "200", 10);
        const logDir = pathModule.dirname(logger.path);
        const filePath = pathModule.join(logDir, `${logName}.log`);
        try {
          const content = await fs.readFile(filePath, "utf8");
          const lines = content.split("\n");
          sendText(response, 200, lines.slice(-tail).join("\n"));
        } catch {
          sendText(response, 404, `Log file ${logName}.log not found.`);
        }
        return;
      }

      if (method === "GET" && pathname === "/voice-runtime.js") {
        await sendFile(
          response,
          pathModule.join(assetsRoot, "dist-voice", "voice-runtime.js"),
          "application/javascript; charset=utf-8"
        );
        return;
      }

      if (method === "GET" && pathname === "/voice-host") {
        sendHtml(
          response,
          200,
          `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Jarvis Voice Host</title>
  </head>
  <body>
    <script>
      window.__JARVEY_SIDECAR_BASE__ = "http://${HOST}:${parsePort()}";
      window.__JARVEY_AUTH_TOKEN__ = ${JSON.stringify(authToken)};
      window.onerror = function(msg, src, line, col, err) {
        window.webkit?.messageHandlers?.jarveyVoice?.postMessage({
          type: "error",
          message: "JS Error: " + msg + " at " + src + ":" + line + ":" + col
        });
      };
      window.addEventListener("unhandledrejection", function(e) {
        var msg = e.reason instanceof Error ? e.reason.message : String(e.reason);
        window.webkit?.messageHandlers?.jarveyVoice?.postMessage({
          type: "error",
          message: "Unhandled rejection: " + msg
        });
      });
    </script>
    <script src="/voice-runtime.js"></script>
  </body>
</html>`
        );
        return;
      }

      if (method === "GET" && pathname === "/settings") {
        sendJson(response, 200, settingsStore.get());
        return;
      }

      if (method === "PUT" && pathname === "/settings") {
        const update = await readJson<SettingsUpdate>(request);
        sendJson(response, 200, settingsStore.update(update));
        return;
      }

      if (method === "POST" && pathname === "/realtime/client-secret") {
        const apiKey = settingsStore.getApiKey();
        if (!apiKey) {
          sendJson(response, 400, {
            error: "OpenAI API key is not configured."
          });
          return;
        }
        sendJson(response, 200, await createRealtimeClientSecret(apiKey));
        return;
      }

      if (method === "GET" && pathname === "/memory/recent") {
        const limit = Number.parseInt(url.searchParams.get("limit") ?? "12", 10);
        sendJson(response, 200, backendRuntime.memoryStore.listRecent(limit));
        return;
      }

      if (method === "POST" && pathname === "/memory/search") {
        const input = await readJson<MemorySearchInput>(request);
        sendJson(response, 200, backendRuntime.memoryStore.search(input));
        return;
      }

      if (method === "POST" && pathname === "/memory/classify") {
        const input = await readJson<MemorySaveInput>(request);
        sendJson(response, 200, evaluateMemoryWrite(input));
        return;
      }

      if (method === "POST" && pathname === "/memory/save") {
        const input = await readJson<MemorySaveInput>(request);
        const policy = evaluateMemoryWrite(input);
        if (policy.decision === "block") {
          sendJson(response, 200, {
            status: "blocked",
            reason: policy.reason
          });
          return;
        }

        const memory = backendRuntime.memoryStore.save(
          { ...input, tags: policy.normalizedTags },
          policy.reason
        );
        sendJson(response, 200, {
          status: policy.decision === "approval_required" ? "saved_after_approval" : "saved",
          reason: policy.reason,
          memory
        });
        return;
      }

      if (method === "POST" && pathname === "/memory/forget") {
        const input = await readJson<MemoryForgetInput>(request);
        sendJson(response, 200, backendRuntime.memoryStore.forget(input));
        return;
      }

      if (method === "GET" && pathname === "/codex/status") {
        sendJson(response, 200, await codexBridge.status());
        return;
      }

      if (method === "GET" && pathname === "/codex/events/recent") {
        const limit = Math.min(
          Math.max(Number.parseInt(url.searchParams.get("limit") ?? "24", 10) || 24, 1),
          200
        );
        sendJson(response, 200, await codexBridge.recentEvents(limit));
        return;
      }

      if (method === "POST" && pathname === "/codex/command") {
        const input = await readJson<CodexCommandRequest>(request);
        sendJson(response, 200, await codexBridge.command(input));
        return;
      }

      if (method === "POST" && pathname === "/codex/pm-status") {
        const input = await readJson<{
          query?: string;
          agent?: "codex" | "claude";
          quiet?: boolean;
        }>(request);
        sendJson(
          response,
          200,
          await codexBridge.pmStatus(input.query, input.agent ?? "codex", input.quiet === true)
        );
        return;
      }

      if (method === "POST" && pathname === "/app/paste") {
        const input = await readJson<{ app?: string; text?: string; submit?: boolean }>(request);
        if (!input.app || !input.text) {
          sendJson(response, 400, { error: "Both 'app' and 'text' are required." });
          return;
        }
        await inputBridge.resumeActions();
        const result = await inputBridge.pasteIntoApp(input.app, input.text, input.submit === true);
        sendJson(response, result.ok ? 200 : 502, result);
        return;
      }

      if (method === "POST" && pathname === "/app/click") {
        const input = await readJson<{ app?: string; label?: string }>(request);
        if (!input.app || !input.label) {
          sendJson(response, 400, { error: "Both 'app' and 'label' are required." });
          return;
        }
        await inputBridge.resumeActions();
        const result = await inputBridge.clickInApp(input.app, input.label);
        sendJson(response, result.ok ? 200 : 502, result);
        return;
      }

      if (method === "POST" && pathname === "/files/open") {
        const input = await readJson<{ path?: string; query?: string; appName?: string }>(request);
        const result = await openFileForUser(input.path, input.query, input.appName);
        sendJson(response, result.ok ? 200 : 404, result);
        return;
      }

      if (method === "GET" && pathname === "/agents/status") {
        const agents = await Promise.all(
          (["codex", "claude"] as const).map(async (agentApp) => {
            const status = await inputBridge.agentStatus(agentApp);
            return {
              agent: agentApp,
              running: status.running,
              installed: status.installed ?? status.running,
              pid: status.pid
            };
          })
        );
        sendJson(response, 200, { agents });
        return;
      }

      if (method === "POST" && pathname === "/codex/stop") {
        const result = await codexBridge.stop();
        await inputBridge.emergencyStop();
        sendJson(response, 200, result);
        return;
      }

      if (method === "GET" && pathname === "/backend/events/recent") {
        const limit = Math.min(
          Math.max(Number.parseInt(url.searchParams.get("limit") ?? "24", 10) || 24, 1),
          200
        );
        const taskId = url.searchParams.get("taskId");
        const filtered = taskId
          ? backendEventHistory.filter((event) => event.taskId === taskId)
          : backendEventHistory;
        sendJson(response, 200, filtered.slice(0, limit));
        return;
      }

      if (method === "GET" && pathname === "/backend/events") {
        response.writeHead(200, {
          ...localResponseHeaders("text/event-stream; charset=utf-8"),
          Connection: "keep-alive"
        });
        response.write(eventFrame("ready", { pid: process.pid }));
        sseClients.add(response);
        request.on("close", () => {
          sseClients.delete(response);
        });
        return;
      }

      if (method === "POST" && pathname === "/backend/tasks") {
        const body = await readJson<Omit<BackendTaskInput, "requestId"> & { requestId?: string }>(request);
        if (settingsStore.get().browserControlMode === "headless") {
          await inputBridge.emergencyStop();
        } else {
          await inputBridge.resumeActions();
        }
        const taskId = body.requestId ?? nanoid();
        const input: BackendTaskInput = {
          requestId: taskId,
          userRequest: body.userRequest,
          transcriptHistory: body.transcriptHistory ?? [],
          activeAppHint: body.activeAppHint,
          memoryContext: body.memoryContext
        };

        void backendRuntime.startTask(input).catch(() => undefined);
        sendJson(response, 202, {
          taskId
        });
        return;
      }

      if (method === "POST" && pathname === "/backend/tasks/run") {
        const body = await readJson<Omit<BackendTaskInput, "requestId"> & { requestId?: string }>(request);
        if (settingsStore.get().browserControlMode === "headless") {
          await inputBridge.emergencyStop();
        } else {
          await inputBridge.resumeActions();
        }
        const input: BackendTaskInput = {
          requestId: body.requestId ?? nanoid(),
          userRequest: body.userRequest,
          transcriptHistory: body.transcriptHistory ?? [],
          activeAppHint: body.activeAppHint,
          memoryContext: body.memoryContext
        };
        sendJson(response, 200, await backendRuntime.startTask(input));
        return;
      }

      if (method === "POST" && pathname === "/backend/tasks/cancel-all") {
        const cancelled = backendRuntime.cancelAll("Stop all requested");
        await codexBridge.stop();
        await inputBridge.emergencyStop();
        sendJson(response, 200, { ok: true, cancelled });
        return;
      }

      const approveMatch = pathname.match(/^\/backend\/tasks\/([^/]+)\/approve$/);
      if (method === "POST" && approveMatch) {
        const body = await readJson<Omit<BackendApprovalDecision, "taskId" | "approve">>(request);
        backendRuntime.approve({
          taskId: approveMatch[1] ?? "",
          approvalId: body.approvalId,
          alwaysApply: body.alwaysApply
        });
        sendJson(response, 200, { ok: true });
        return;
      }

      const rejectMatch = pathname.match(/^\/backend\/tasks\/([^/]+)\/reject$/);
      if (method === "POST" && rejectMatch) {
        const body = await readJson<Omit<BackendApprovalDecision, "taskId" | "approve">>(request);
        backendRuntime.reject({
          taskId: rejectMatch[1] ?? "",
          approvalId: body.approvalId,
          alwaysApply: body.alwaysApply,
          message: body.message
        });
        sendJson(response, 200, { ok: true });
        return;
      }

      const cancelMatch = pathname.match(/^\/backend\/tasks\/([^/]+)\/cancel$/);
      if (method === "POST" && cancelMatch) {
        backendRuntime.cancel(cancelMatch[1] ?? "");
        await inputBridge.emergencyStop();
        sendJson(response, 200, { ok: true });
        return;
      }

      sendText(response, 404, "Not found");
    } catch (error) {
      const msg = error instanceof Error ? error.message : "Unhandled sidecar failure.";
      logger.error(`${method} ${pathname} failed`, { error: msg, stack: error instanceof Error ? error.stack : undefined });
      sendJson(response, 500, { error: msg });
    }
  });

  const port = parsePort();
  server.listen(port, HOST, () => {
    const address = server.address();
    const resolvedPort =
      typeof address === "object" && address ? address.port : port;
    const payload = {
      host: HOST,
      port: resolvedPort,
      pid: process.pid
    };
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  });
}

void main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});
