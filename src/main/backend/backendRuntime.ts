import { EventEmitter } from "node:events";
import fs from "node:fs";
import path from "node:path";
import {
  run,
  type RunStreamEvent,
  type RunToolApprovalItem
} from "@openai/agents";
import { nanoid } from "nanoid";
import type {
  BackendApprovalDecision,
  BackendTaskEvent,
  BackendTaskInput,
  BackendTaskResult,
  SettingsData
} from "../../shared/types";
import { resolveAppLogsDirectory } from "../../shared/appIdentity";
import { ApprovalHub } from "./approvalHub";
import { buildAgents, formatApprovalRequest, streamEventToBackendEvent, type BuiltAgents } from "./agents";
import { MemoryStore } from "./memory/memoryStore";

const LOG_DIR = resolveAppLogsDirectory();
const LOG_FILE = path.join(LOG_DIR, "backend.log");

function blogLine(level: string, msg: string, data?: unknown) {
  let line = `${new Date().toISOString()} [${level}] ${msg}`;
  if (data !== undefined) {
    try { line += ` ${JSON.stringify(data)}`; } catch { line += " [unserializable]"; }
  }
  try { fs.appendFileSync(LOG_FILE, line + "\n"); } catch { /* best-effort */ }
}

type TaskRecord = {
  id: string;
  controller: AbortController;
  completed: boolean;
};

type RunInput = Parameters<typeof run>[1];

function isTerminalEvent(event: BackendTaskEvent): boolean {
  return event.type === "completed" || event.type === "failed" || event.type === "cancelled";
}

export interface SettingsAccessor {
  get(): SettingsData;
}

export class BackendRuntime extends EventEmitter<{
  event: [BackendTaskEvent];
}> {
  readonly memoryStore: MemoryStore;
  private readonly approvalHub = new ApprovalHub();
  private readonly tasks = new Map<string, TaskRecord>();
  private readonly terminalTaskIds = new Set<string>();

  constructor(
    private readonly settingsStore: SettingsAccessor,
    private readonly workingDirectory: string,
    dataDirectory: string
  ) {
    super();
    const dbPath = path.join(dataDirectory, "memory", "durable-memory.sqlite");
    this.memoryStore = new MemoryStore(dbPath);
  }

  async startTask(input: BackendTaskInput): Promise<BackendTaskResult> {
    // Cancel any in-flight tasks so only one agent controls the screen at a time.
    for (const [existingId, existing] of this.tasks) {
      if (!existing.completed) {
        this.cancelTask(existingId, "Superseded by new task");
      }
    }

    const taskId = input.requestId || nanoid();
    const controller = new AbortController();
    this.terminalTaskIds.delete(taskId);
    this.tasks.set(taskId, { id: taskId, controller, completed: false });
    let agents: BuiltAgents | null = null;

    blogLine("INFO", `Task starting: ${taskId}`, { userRequest: input.userRequest.slice(0, 200) });

    this.emitEvent({
      taskId,
      type: "started",
      createdAt: new Date().toISOString(),
      summary: `Goal: ${input.userRequest.slice(0, 180)}`
    });

    try {
      agents = await buildAgents({
        taskId,
        memoryStore: this.memoryStore,
        settings: this.settingsStore.get(),
        workingDirectory: this.workingDirectory,
        onEvent: (event) => this.emitEvent(event)
      });

      let runInput: string = this.buildRunPrompt(input);
      let result = await this.runOnce(agents.operatorSupervisor, runInput, controller.signal, taskId);

      while (result.interruptions.length) {
        this.throwIfAborted(controller.signal);
        const state = result.state;
        for (const interruption of result.interruptions) {
          const decision = await this.waitForApproval(taskId, interruption, controller.signal);
          if (decision.approve) {
            state.approve(interruption, {
              alwaysApprove: decision.alwaysApply
            });
            this.emitEvent({
              taskId,
              type: "approved",
              createdAt: new Date().toISOString(),
              approvalId: decision.approvalId,
              summary: "Approval granted."
            });
          } else {
            state.reject(interruption, {
              alwaysReject: decision.alwaysApply,
              message:
                decision.message ??
                `Tool execution for "${interruption.name ?? interruption.toolName ?? "tool"}" was rejected by the user.`
            });
            this.emitEvent({
              taskId,
              type: "rejected",
              createdAt: new Date().toISOString(),
              approvalId: decision.approvalId,
              summary: "Approval rejected."
            });
          }
        }
        result = await this.runOnce(agents.operatorSupervisor, result.state, controller.signal, taskId);
      }

      this.throwIfAborted(controller.signal);
      blogLine("INFO", `Task completed: ${taskId}`, { agent: result.lastAgent?.name, outputLength: result.finalOutput?.length });

      const finalResult: BackendTaskResult = {
        taskId,
        summary: result.finalOutput || "Task completed.",
        outputText: result.finalOutput || "",
        agent: result.lastAgent?.name ?? "OperatorSupervisor",
        completedAt: new Date().toISOString()
      };

      const task = this.tasks.get(taskId);
      if (task) {
        task.completed = true;
      }

      this.emitEvent({
        taskId,
        type: "completed",
        createdAt: finalResult.completedAt,
        result: finalResult
      });
      return finalResult;
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "The backend task failed unexpectedly.";
      blogLine("ERROR", `Task failed: ${taskId}`, { error: message, stack: error instanceof Error ? error.stack : undefined });
      if (controller.signal.aborted) {
        this.emitEvent({
          taskId,
          type: "cancelled",
          createdAt: new Date().toISOString(),
          summary: "Backend task cancelled."
        });
      } else {
        this.emitEvent({
          taskId,
          type: "failed",
          createdAt: new Date().toISOString(),
          summary: message
        });
      }
      throw error;
    } finally {
      if (agents) {
        await agents.close();
      }
      this.tasks.delete(taskId);
      this.approvalHub.rejectTask(taskId, "Task finished");
    }
  }

  approve(decision: Omit<BackendApprovalDecision, "approve"> & { alwaysApply?: boolean }): void {
    this.approvalHub.resolve({
      ...decision,
      approve: true
    });
  }

  reject(decision: Omit<BackendApprovalDecision, "approve"> & { alwaysApply?: boolean; message?: string }): void {
    this.approvalHub.resolve({
      ...decision,
      approve: false
    });
  }

  cancel(taskId: string): void {
    this.cancelTask(taskId, "Task cancelled");
  }

  cancelAll(reason = "Stop all requested"): string[] {
    const cancelled: string[] = [];
    for (const [taskId, task] of this.tasks) {
      if (!task.completed) {
        this.cancelTask(taskId, reason);
        cancelled.push(taskId);
      }
    }
    return cancelled;
  }

  activeTaskIds(): string[] {
    return Array.from(this.tasks.values())
      .filter((task) => !task.completed && !this.terminalTaskIds.has(task.id))
      .map((task) => task.id);
  }

  private cancelTask(taskId: string, reason: string): void {
    const task = this.tasks.get(taskId);
    if (!task) {
      return;
    }
    task.completed = true;
    task.controller.abort();
    this.approvalHub.rejectTask(taskId, reason);
    blogLine("INFO", `Task cancelled: ${taskId}`, { reason });
    this.emitEvent({
      taskId,
      type: "cancelled",
      createdAt: new Date().toISOString(),
      summary: reason
    });
  }

  private async runOnce(
    agent: Parameters<typeof run>[0],
    input: RunInput,
    signal: AbortSignal,
    taskId: string
  ) {
    const agentName = "name" in agent && typeof agent.name === "string" ? agent.name : "unknown";
    blogLine("INFO", `runOnce: ${taskId}`, { agent: agentName });
    this.throwIfAborted(signal);
    const result = await run(agent, input, {
      stream: true,
      signal,
      maxTurns: 100
    });

    for await (const event of result) {
      this.throwIfAborted(signal);
      this.forwardStreamEvent(taskId, event);
    }

    this.throwIfAborted(signal);
    await result.completed;
    this.throwIfAborted(signal);
    blogLine("INFO", `runOnce completed: ${taskId}`, {
      interruptions: result.interruptions.length,
      lastAgent: result.lastAgent?.name
    });
    return result;
  }

  private forwardStreamEvent(taskId: string, event: RunStreamEvent): void {
    const task = this.tasks.get(taskId);
    if (this.terminalTaskIds.has(taskId) || task?.controller.signal.aborted) {
      return;
    }
    const mapped = streamEventToBackendEvent(taskId, event);
    if (mapped) {
      this.emitEvent(mapped);
    }
  }

  private throwIfAborted(signal: AbortSignal): void {
    if (signal.aborted) {
      throw new Error("Task cancelled");
    }
  }

  private async waitForApproval(
    taskId: string,
    interruption: RunToolApprovalItem,
    signal: AbortSignal
  ): Promise<BackendApprovalDecision> {
    const formatted = formatApprovalRequest(interruption);
    const pending = this.approvalHub.createRequest({
      taskId,
      kind: formatted.kind,
      toolName: formatted.toolName,
      summary: formatted.summary,
      detail: formatted.detail,
      rawItem: interruption.toJSON()
    });

    this.emitEvent({
      taskId,
      type: "approval_requested",
      createdAt: new Date().toISOString(),
      approval: pending.request
    });

    return await Promise.race([
      pending.waitForDecision,
      new Promise<BackendApprovalDecision>((_resolve, reject) => {
        signal.addEventListener(
          "abort",
          () => reject(new Error("Task cancelled")),
          { once: true }
        );
      })
    ]);
  }

  private buildRunPrompt(input: BackendTaskInput): string {
    const transcript = input.transcriptHistory
      .slice(-10)
      .map((entry) => `${entry.role}: ${entry.text}`)
      .join("\n");

    const recentMemories = this.memoryStore
      .listRecent(8)
      .map((memory) => `- [${memory.kind}] ${memory.subject}: ${memory.content}`)
      .join("\n");

    return [
      "You are handling a desktop task.",
      "Operate as Jarvis, a local macOS assistant with maximum autonomy for ordinary local work and strict guardrails for sensitive or irreversible actions.",
      "",
      "<USER_REQUEST>",
      input.userRequest,
      "</USER_REQUEST>",
      "",
      input.activeAppHint
        ? `<ACTIVE_APP_HINT>\n${input.activeAppHint}\n</ACTIVE_APP_HINT>\n`
        : "",
      transcript
        ? `<TRANSCRIPT_HISTORY>\n${transcript}\n</TRANSCRIPT_HISTORY>\n`
        : "",
      recentMemories
        ? `<RECENT_MEMORY>\n${recentMemories}\n</RECENT_MEMORY>\n`
        : "",
      input.memoryContext
        ? `<MEMORY_CONTEXT>\n${input.memoryContext}\n</MEMORY_CONTEXT>`
        : ""
    ]
      .filter(Boolean)
      .join("\n");
  }

  private emitEvent(event: BackendTaskEvent): void {
    if (this.terminalTaskIds.has(event.taskId)) {
      return;
    }
    if (isTerminalEvent(event)) {
      this.terminalTaskIds.add(event.taskId);
      const task = this.tasks.get(event.taskId);
      if (task) {
        task.completed = true;
      }
    }
    this.emit("event", event);
  }
}
