import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import Database from "better-sqlite3";
import type {
  CodexBridgeEvent,
  CodexCommandRequest,
  CodexCommandResult,
  CodexIntegrationConfig,
  CodexPmStatus,
  CodexStatus,
  SettingsData,
  SettingsUpdate
} from "../shared/types";
import type { CodexBridgeMode } from "../shared/samanthaConfig";
import { defaultSettings } from "../shared/defaults";
import { redactSensitiveText, sensitivePatterns } from "../shared/sensitiveContent";
import { NativeComputerBridge } from "../main/backend/tools/nativeComputerBridge";

const execFileAsync = promisify(execFile);
const DRIVE_TTL_MS = 10 * 60 * 1000;

type CodexSessionRow = {
  rollout_path: string;
  title: string;
  updated_at: number;
};

type CodexSessionRead = {
  text: string;
  title: string;
  updatedAt: number;
  sourcePath: string;
};

export interface CodexSettingsStore {
  get(): SettingsData;
  update(update: SettingsUpdate): SettingsData;
}

function expandHome(filePath: string): string {
  if (filePath === "~") {
    return os.homedir();
  }
  if (filePath.startsWith("~/")) {
    return path.join(os.homedir(), filePath.slice(2));
  }
  return filePath;
}

function isSensitiveCommand(command: string): string | undefined {
  const checks = [
    { pattern: sensitivePatterns.credentials, reason: "Codex prompts that mention credentials or secrets need explicit user handling." },
    { pattern: sensitivePatterns.payments, reason: "Payments and purchases are not sent to Codex automatically." },
    { pattern: sensitivePatterns.externalSends, reason: "External sends or submissions need explicit confirmation outside the bridge." },
    { pattern: sensitivePatterns.destructiveShellBroad, reason: "Destructive or privileged actions are blocked by the Codex bridge." }
  ];
  return checks.find((check) => check.pattern.test(command))?.reason;
}

export class CodexBridge {
  constructor(
    private readonly settingsStore: CodexSettingsStore,
    private readonly nativeBridge: NativeComputerBridge
  ) {}

  async status(): Promise<CodexStatus> {
    const config = this.currentConfig();
    const normalized = this.enforceDriveExpiry(config);
    await this.ensureFiles(normalized);
    const nativeStatus = await this.nativeBridge.agentStatus("codex");
    const fallback = nativeStatus.running ? nativeStatus : await this.psCodexStatus();
    const recentEvents = await this.recentEvents(1);
    const queueDepth = await this.queueDepth(normalized.inboxPath);

    return {
      enabled: normalized.enabled,
      mode: normalized.mode,
      codexRunning: fallback.running,
      codexPid: fallback.pid,
      queueDepth,
      heartbeatAt: new Date().toISOString(),
      inboxPath: normalized.inboxPath,
      outboxPath: normalized.outboxPath,
      eventsPath: normalized.eventsPath,
      driveExpiresAt: normalized.driveExpiresAt,
      lastEvent: recentEvents[0]
    };
  }

  async recentEvents(limit = 24): Promise<CodexBridgeEvent[]> {
    const config = this.currentConfig();
    await this.ensureFiles(config);
    try {
      const raw = await fs.readFile(config.eventsPath, "utf8");
      return raw
        .split("\n")
        .filter(Boolean)
        .slice(-Math.max(1, Math.min(limit, 200)))
        .reverse()
        .map((line) => JSON.parse(line) as CodexBridgeEvent);
    } catch {
      return [];
    }
  }

  async command(request: CodexCommandRequest): Promise<CodexCommandResult> {
    const config = this.enforceDriveExpiry(this.currentConfig());
    await this.ensureFiles(config);

    if (!config.enabled) {
      return await this.recordResult("blocked", "Codex bridge is disabled.", request.command, {
        needsUserApproval: false,
        nextAction: "Enable agent integration in Jarvis settings."
      });
    }

    const userCommand = request.command.trim();
    const command = this.buildPmPrompt(userCommand);
    if (!command) {
      return await this.recordResult("blocked", "Codex command is empty.", request.command, {
        needsUserApproval: false
      });
    }

    const sensitiveReason = isSensitiveCommand(userCommand);
    if (sensitiveReason) {
      return await this.recordResult("blocked", sensitiveReason, command, {
        needsUserApproval: true,
        nextAction: "Review and send the prompt manually if you still want Codex to handle it."
      });
    }

    if (request.requireConfirmation) {
      await this.writeInbox(config, request.intent, command);
      return await this.recordResult("prepared", "Jarvis prepared an execution brief and is awaiting your confirmation.", command, {
        needsUserApproval: true,
        nextAction: "Confirm by voice and Jarvis will send it.",
        pmPrompt: command
      });
    }

    const agent = request.agent ?? "codex";
    const agentName = agent === "codex" ? "Codex" : "Claude";

    await this.nativeBridge.resumeActions();
    // Default flow: type the brief into the CURRENT chat and leave it unsent;
    // the user reviews it and confirms ("envíalo") before Enter is pressed.
    const autoSend = request.autoSend === true;
    const sendResult = await this.nativeBridge.sendAgentPrompt(command, agent, {
      newChat: request.newChat === true,
      submit: autoSend
    });
    if (sendResult.ok && sendResult.handoff) {
      await this.writeInbox(config, request.intent, command);
      return await this.recordResult(
        "prepared",
        `No se puede operar la caja de ${agentName} de forma segura por Accessibility, así que Jarvis dejó el brief copiado en el portapapeles y la app al frente. El usuario solo debe pegarlo con Cmd+V y enviarlo.`,
        command,
        {
          needsUserApproval: true,
          nextAction: `Pega con Cmd+V en el chat de ${agentName} y presiona Enter.`,
          pmPrompt: command
        }
      );
    }
    if (!sendResult.ok) {
      await this.writeInbox(config, request.intent, command);
      return await this.recordResult("blocked", sendResult.error ?? `${agentName} could not be controlled natively.`, command, {
        needsUserApproval: true,
        nextAction: `Open ${agentName} manually or check Accessibility permission.`,
        pmPrompt: command
      });
    }

    await fs.writeFile(
      config.outboxPath,
      `# Last Prompt Sent To Codex\n\n${command}\n\nSent: ${new Date().toISOString()}\n`,
      "utf8"
    );
    if (!autoSend) {
      // An unverified (blind) delivery may have missed the box entirely — say
      // so, instead of letting the voice agent claim it is written. The
      // deferred submit re-pastes when it finds the box without the brief.
      const preparedNote = sendResult.verified
        ? `Jarvis typed the brief into ${agentName}'s prompt box. It has NOT been sent — awaiting the user's confirmation.`
        : `Jarvis typed the brief into ${agentName} but could NOT verify it reached the prompt box. Ask the user to glance at ${agentName}; on "envíalo" Jarvis re-pastes it if missing and presses Enter.`;
      return await this.recordResult(
        "prepared",
        preparedNote,
        command,
        {
          needsUserApproval: true,
          nextAction: `Say "envíalo" and Jarvis will press Enter in ${agentName}.`,
          pmPrompt: command,
          detail: sendResult.verified ? "delivery:typed-verified" : "delivery:typed-blind"
        }
      );
    }

    const deliveryNote = sendResult.verified
      ? `Jarvis delivered the brief to ${agentName}'s prompt box and sent it.`
      : `Jarvis pasted the brief into ${agentName}'s prompt box and pressed Enter. ${agentName} no expone el contenido por Accessibility, así que vale la pena confirmar visualmente que el mensaje aparece como enviado.`;
    return await this.recordResult("sent", deliveryNote, command, {
      needsUserApproval: false,
      nextAction: `Jarvis can now read ${agentName} status and summarize progress.`,
      pmPrompt: command,
      detail: sendResult.verified ? "delivery:verified" : "delivery:blind"
    });
  }

  /** Discards a typed-but-unsent brief by clearing the agent's chat box. */
  async discardPrompt(agent: "codex" | "claude" = "codex"): Promise<CodexCommandResult> {
    const agentName = agent === "codex" ? "Codex" : "Claude";
    await this.nativeBridge.resumeActions();
    const result = await this.nativeBridge.discardAgentPrompt(agent);
    if (!result.ok) {
      return await this.recordResult("blocked", result.error ?? `${agentName} could not be controlled natively.`, "", {
        needsUserApproval: true,
        nextAction: `Clear ${agentName}'s prompt box manually.`
      });
    }
    return await this.recordResult("stopped", `Jarvis discarded the pending brief in ${agentName}.`, "", {
      needsUserApproval: false
    });
  }

  /** Deferred send: presses Enter in the agent's chat box after the user confirmed. */
  async submitPrompt(agent: "codex" | "claude" = "codex"): Promise<CodexCommandResult> {
    const agentName = agent === "codex" ? "Codex" : "Claude";
    await this.nativeBridge.resumeActions();
    const result = await this.nativeBridge.submitAgentPrompt(agent);
    if (!result.ok) {
      return await this.recordResult("blocked", result.error ?? `${agentName} could not be controlled natively.`, "", {
        needsUserApproval: true,
        nextAction: `Open ${agentName} and press Enter manually.`
      });
    }
    return await this.recordResult("sent", `Jarvis sent the pending brief in ${agentName}.`, "", {
      needsUserApproval: false,
      nextAction: `Jarvis can now read ${agentName} status and summarize progress.`
    });
  }

  async pmStatus(
    query?: string,
    agent: "codex" | "claude" = "codex",
    quiet = false
  ): Promise<CodexPmStatus> {
    const status = await this.status();
    const read = await this.nativeBridge.readAgent(agent);
    const sessionRead = agent === "codex" ? await this.readLatestCodexSessionText() : null;
    const recentEvents = await this.recentEvents(1);
    const visibleText = redactSensitiveText((sessionRead?.text || read.text).trim());
    const excerpt = this.lastUsefulLines(visibleText, 18);
    const readableExcerpt = this.summaryTextFromExcerpt(excerpt) || excerpt;
    const operationalText = this.operationalTextFromExcerpt(excerpt);
    const needsUserAttention = this.hasNeedsUserAttentionSignal(operationalText);
    const working = this.hasWorkingSignal(operationalText || readableExcerpt);
    const agentRunning = agent === "codex" ? status.codexRunning : read.running;
    const currentState: CodexPmStatus["currentState"] =
      !agentRunning ? "offline" :
        needsUserAttention ? "needs_user" :
          working ? "working" :
            readableExcerpt ? "idle" : "unknown";

    const agentName = agent === "codex" ? "Codex" : "Claude";
    const summary = this.summarizePmStatus({
      query,
      agentName,
      codexRunning: agentRunning,
      mode: status.mode,
      queueDepth: status.queueDepth,
      needsUserAttention,
      currentState,
      excerpt: readableExcerpt,
      lastEvent: recentEvents[0],
      readError: sessionRead ? undefined : read.error,
      sourceTitle: sessionRead?.title
    });

    const event = quiet
      ? undefined
      : await this.appendEvent({
          type: "summary",
          summary,
          detail: readableExcerpt || read.error
        });

    return {
      ok: Boolean(sessionRead) || read.ok || agentRunning,
      summary,
      codexRunning: agentRunning,
      needsUserAttention,
      currentState,
      lastReadableText: readableExcerpt || undefined,
      lastEvent: event,
      capturedAt: sessionRead ? new Date(sessionRead.updatedAt * 1000).toISOString() : read.capturedAt
    };
  }

  async stop(): Promise<CodexCommandResult> {
    const config = this.currentConfig();
    if (config.mode === "drive") {
      this.settingsStore.update({
        codexIntegration: {
          ...config,
          mode: "assist",
          driveExpiresAt: undefined
        }
      });
    }
    return await this.recordResult("stopped", "Codex bridge stopped and returned to Assist mode.", "", {
      needsUserApproval: false
    });
  }

  private currentConfig(): CodexIntegrationConfig {
    const raw = this.settingsStore.get().codexIntegration ?? defaultSettings.codexIntegration;
    return {
      ...defaultSettings.codexIntegration,
      ...raw,
      inboxPath: expandHome(raw.inboxPath || defaultSettings.codexIntegration.inboxPath),
      outboxPath: expandHome(raw.outboxPath || defaultSettings.codexIntegration.outboxPath),
      eventsPath: expandHome(raw.eventsPath || defaultSettings.codexIntegration.eventsPath)
    };
  }

  private enforceDriveExpiry(config: CodexIntegrationConfig): CodexIntegrationConfig {
    if (config.godMode || config.mode !== "drive" || !config.driveExpiresAt) {
      return config;
    }
    const expiresAt = Date.parse(config.driveExpiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt > Date.now()) {
      return config;
    }
    const next = {
      ...config,
      mode: "assist" as CodexBridgeMode,
      driveExpiresAt: undefined
    };
    this.settingsStore.update({ codexIntegration: next });
    return next;
  }

  private async ensureFiles(config: CodexIntegrationConfig): Promise<void> {
    await Promise.all([
      fs.mkdir(path.dirname(config.inboxPath), { recursive: true }),
      fs.mkdir(path.dirname(config.outboxPath), { recursive: true }),
      fs.mkdir(path.dirname(config.eventsPath), { recursive: true })
    ]);
    await Promise.all([
      fs.appendFile(config.inboxPath, ""),
      fs.appendFile(config.outboxPath, ""),
      fs.appendFile(config.eventsPath, "")
    ]);
  }

  private async writeInbox(config: CodexIntegrationConfig, intent: string, command: string): Promise<void> {
    await fs.writeFile(
      config.inboxPath,
      [
        "# Jarvis To Codex",
        "",
        `Intent: ${intent}`,
        `Prepared: ${new Date().toISOString()}`,
        "",
        command,
        ""
      ].join("\n"),
      "utf8"
    );
  }

  private buildPmPrompt(command: string): string {
    const trimmed = command.trim();
    if (!trimmed) {
      return "";
    }
    // Send exactly what Jarvis composed — the agent apps don't need wrapper
    // boilerplate, and the user sees whatever lands in the prompt box.
    return trimmed;
  }

  private async queueDepth(inboxPath: string): Promise<number> {
    try {
      const raw = await fs.readFile(inboxPath, "utf8");
      return raw.trim().length ? 1 : 0;
    } catch {
      return 0;
    }
  }

  private async recordResult(
    status: CodexCommandResult["status"],
    summary: string,
    command: string,
    extra: Pick<CodexCommandResult, "needsUserApproval"> &
      Pick<CodexCommandResult, "nextAction"> &
      Pick<CodexCommandResult, "pmPrompt"> & { detail?: string }
  ): Promise<CodexCommandResult> {
    const event = await this.appendEvent({
      type: status === "observed" ? "status" : status,
      summary,
      detail: extra.detail,
      command: command || undefined
    });
    return {
      status,
      summary,
      nextAction: extra.nextAction,
      needsUserApproval: extra.needsUserApproval,
      pmPrompt: extra.pmPrompt,
      event
    };
  }

  private lastUsefulLines(text: string, maxLines: number): string {
    return text
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 1)
      .slice(-maxLines)
      .join("\n")
      .slice(-4_000);
  }

  private async readLatestCodexSessionText(): Promise<CodexSessionRead | undefined> {
    const dbPath = path.join(os.homedir(), ".codex", "state_5.sqlite");
    try {
      await fs.access(dbPath);
    } catch {
      return undefined;
    }

    let db: Database.Database | undefined;
    try {
      db = new Database(dbPath, { readonly: true, fileMustExist: true });
      const row = db.prepare(`
        SELECT rollout_path, title, updated_at
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT 1
      `).get() as CodexSessionRow | undefined;
      if (!row?.rollout_path) {
        return undefined;
      }

      const raw = await fs.readFile(row.rollout_path, "utf8");
      const items = raw
        .split("\n")
        .filter(Boolean)
        .slice(-600)
        .flatMap((line) => this.codexSessionLineToText(line));
      const text = redactSensitiveText(items.slice(-30).join("\n"));
      if (!text.trim()) {
        return undefined;
      }
      return {
        text,
        title: row.title,
        updatedAt: row.updated_at,
        sourcePath: row.rollout_path
      };
    } catch {
      return undefined;
    } finally {
      db?.close();
    }
  }

  private codexSessionLineToText(line: string): string[] {
    try {
      const parsed = JSON.parse(line) as {
        type?: string;
        payload?: {
          type?: string;
          role?: string;
          content?: unknown;
          message?: string;
          phase?: string;
        };
      };
      const payload = parsed.payload;
      if (!payload) {
        return [];
      }
      if (parsed.type === "response_item" && payload.type === "message") {
        const text = this.extractCodexContentText(payload.content);
        if (!text) {
          return [];
        }
        const role = payload.role === "user" ? "User" : "Codex";
        return [`${role}: ${this.compactSessionText(text, role === "User" ? 900 : 2_000)}`];
      }
      if (parsed.type === "event_msg" && typeof payload.message === "string" && payload.message.trim()) {
        return [`Codex event: ${this.compactSessionText(payload.message, 1_200)}`];
      }
      return [];
    } catch {
      return [];
    }
  }

  private extractCodexContentText(content: unknown): string {
    if (typeof content === "string") {
      return content.trim();
    }
    if (!Array.isArray(content)) {
      return "";
    }
    return content
      .flatMap((item) => {
        if (!item || typeof item !== "object") {
          return [];
        }
        const maybeText = (item as { text?: unknown }).text;
        return typeof maybeText === "string" ? [maybeText] : [];
      })
      .join("\n")
      .replace(/\s+\n/g, "\n")
      .trim();
  }

  private compactSessionText(text: string, limit: number): string {
    const compacted = text
      .replace(/\s+/g, " ")
      .trim();
    return compacted.length > limit ? `${compacted.slice(0, limit - 1)}…` : compacted;
  }

  private operationalTextFromExcerpt(excerpt: string): string {
    return excerpt
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => /^Codex:/i.test(line))
      .join("\n");
  }

  private summaryTextFromExcerpt(excerpt: string): string {
    const lines = excerpt
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    const codexLines = lines.filter((line) => /^Codex:/i.test(line));
    if (codexLines.length) {
      return codexLines.slice(-8).join("\n");
    }
    return lines
      .filter((line) => !/^User:/i.test(line))
      .filter((line) => !/^Codex event:\s*(# Files mentioned|## |My request for Codex:|<image\b)/i.test(line))
      .slice(-8)
      .join("\n");
  }

  private hasNeedsUserAttentionSignal(text: string): boolean {
    const lines = text
      .split("\n")
      .map((line) => line.replace(/^Codex:\s*/i, "").replace(/\s+/g, " ").trim())
      .filter(Boolean);

    return lines.some((line) => {
      if (/\b(false positive|falso positivo|heur[ií]stica|detector|clasificador|señales como|signals like|solo marca|solo salga|correg|diagn[oó]stic)/i.test(line)) {
        return false;
      }
      if (/\b(no|not)\s+(approval|confirmation|permission|user input)\s+(needed|required|pending)\b/i.test(line)) {
        return false;
      }
      if (/\b(no hay|sin)\s+(ninguna\s+)?(aprobaci[oó]n|confirmaci[oó]n|interacci[oó]n|permiso)\s+(pendiente|necesaria|requerida)\b/i.test(line)) {
        return false;
      }
      return /^Status:\s*needs_user\b/i.test(line) ||
        /^Needs user:\s*(?!none\b|no\b|ninguno\b|ninguna\b|n\/a\b).{3,}/i.test(line) ||
        /\b(approval|confirmation|permission|authorization|action)\s+required\b/i.test(line) ||
        /\b(waiting for|needs|requires)\s+(your|user)\s+(approval|confirmation|permission|input|action)\b/i.test(line) ||
        /\bplease\s+(approve|confirm|authorize)\b/i.test(line) ||
        /\b(requiere|necesita|espera)\s+(tu|del usuario|usuario)\s+(aprobaci[oó]n|confirmaci[oó]n|permiso|interacci[oó]n|acci[oó]n)\b/i.test(line);
    });
  }

  private hasWorkingSignal(text: string): boolean {
    return /\b(running|working|executing|thinking|building|testing|applying|calling|tool|in progress|revisando|ejecutando|compilando|probando|aplicando)\b/i.test(text);
  }

  private summarizePmStatus(input: {
    query?: string;
    agentName: string;
    codexRunning: boolean;
    mode: CodexBridgeMode;
    queueDepth: number;
    needsUserAttention: boolean;
    currentState: CodexPmStatus["currentState"];
    excerpt: string;
    lastEvent?: CodexBridgeEvent;
    readError?: string;
    sourceTitle?: string;
  }): string {
    const name = input.agentName;
    if (!input.codexRunning) {
      return `${name} no está corriendo. Pide delegarle algo y Jarvis abrirá la app automáticamente.`;
    }
    if (input.needsUserAttention) {
      return `${name} parece necesitar una aprobación o interacción tuya. Revisa la ventana de ${name} antes de continuar.`;
    }
    if (!input.excerpt) {
      return input.readError
        ? `${name} está corriendo, pero no pude leer su contenido por Accessibility: ${input.readError}`
        : `${name} está corriendo, pero aún no hay texto legible suficiente para resumir el avance.`;
    }
    const readable = input.excerpt
      .split("\n")
      .slice(-6)
      .join(" ")
      .replace(/\s+/g, " ")
      .slice(0, 700);
    const source = input.sourceTitle ? ` del hilo "${input.sourceTitle}"` : "";
    if (input.currentState === "working") {
      return `${name} parece estar trabajando${source}. Lectura reciente: ${readable}`;
    }
    if (input.lastEvent?.type === "sent") {
      return `El último brief de Jarvis fue enviado a ${name}${source}. Lectura reciente: ${readable}`;
    }
    return `${name} está disponible y no veo un bloqueo claro${source}. Lectura reciente: ${readable}`;
  }

  private async appendEvent(input: Omit<CodexBridgeEvent, "id" | "createdAt">): Promise<CodexBridgeEvent> {
    const config = this.currentConfig();
    await this.ensureFiles(config);
    const event: CodexBridgeEvent = {
      id: randomUUID(),
      createdAt: new Date().toISOString(),
      ...input
    };
    await fs.appendFile(config.eventsPath, `${JSON.stringify(event)}\n`, "utf8");
    return event;
  }

  private async psCodexStatus(): Promise<{ running: boolean; pid?: number }> {
    try {
      const result = await execFileAsync("/bin/ps", ["-axo", "pid,args"], { timeout: 3_000 });
      const line = result.stdout
        .split("\n")
        .find((row) => row.includes("/Applications/Codex.app/Contents/MacOS/Codex"));
      const pid = line?.trim().match(/^(\d+)/)?.[1];
      return {
        running: Boolean(pid),
        pid: pid ? Number(pid) : undefined
      };
    } catch {
      return { running: false };
    }
  }
}
