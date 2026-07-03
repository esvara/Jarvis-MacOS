import { exec } from "node:child_process";
import { promisify } from "node:util";
import type {
  Shell,
  ShellAction,
  ShellResult
} from "@openai/agents";
import { findHardBlockedShellReason } from "../agents/riskPolicy";

const execAsync = promisify(exec);

// The agent controls timeoutMs; without bounds a missing value runs with no
// timeout at all and a huge one holds the task hostage.
const DEFAULT_COMMAND_TIMEOUT_MS = 30_000;
const MAX_COMMAND_TIMEOUT_MS = 300_000;

function boundedTimeoutMs(requested: number | undefined): number {
  if (typeof requested !== "number" || !Number.isFinite(requested) || requested <= 0) {
    return DEFAULT_COMMAND_TIMEOUT_MS;
  }
  return Math.min(requested, MAX_COMMAND_TIMEOUT_MS);
}

export class HostShell implements Shell {
  constructor(private readonly cwd = process.env.HOME ?? process.cwd()) {}

  async run(action: ShellAction): Promise<ShellResult> {
    const output: ShellResult["output"] = [];

    for (const command of action.commands) {
      const blockedReason = findHardBlockedShellReason(command);
      if (blockedReason) {
        output.push({
          command,
          stdout: "",
          stderr: blockedReason,
          outcome: {
            type: "exit",
            exitCode: 126
          }
        });
        break;
      }

      try {
        const result = await execAsync(command, {
          cwd: this.cwd,
          shell: "/bin/zsh",
          timeout: boundedTimeoutMs(action.timeoutMs),
          maxBuffer: action.maxOutputLength ?? 1024 * 1024
        });
        output.push({
          command,
          stdout: result.stdout,
          stderr: result.stderr,
          outcome: {
            type: "exit",
            exitCode: 0
          }
        });
      } catch (error) {
        const failure = error as {
          stdout?: string;
          stderr?: string;
          code?: number | null;
          signal?: string | null;
          killed?: boolean;
        };
        output.push({
          command,
          stdout: failure.stdout ?? "",
          stderr: failure.stderr ?? String(error),
          outcome:
            failure.killed || failure.signal === "SIGTERM"
              ? { type: "timeout" }
              : { type: "exit", exitCode: failure.code ?? 1 }
        });
        if (failure.killed || failure.signal === "SIGTERM") {
          break;
        }
      }
    }

    return {
      output,
      providerData: {
        cwd: this.cwd
      }
    };
  }
}
