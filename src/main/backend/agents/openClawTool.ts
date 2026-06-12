import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { tool } from "@openai/agents";
import { z } from "zod";
import { classifyTaskRisk } from "./riskPolicy";

const execFileAsync = promisify(execFile);
const MAX_OUTPUT_CHARS = 12_000;

const openClawInputSchema = z.object({
  task: z.string().min(1),
  timeoutSeconds: z.number().int().min(10).max(600).nullable()
});

function trimOutput(value: string): string {
  if (value.length <= MAX_OUTPUT_CHARS) {
    return value;
  }
  return `${value.slice(0, MAX_OUTPUT_CHARS)}\n[trimmed ${value.length - MAX_OUTPUT_CHARS} chars]`;
}

export function buildOpenClawTool(workingDirectory: string) {
  return tool({
    name: "openclaw_delegate_task",
    description:
      "Delegate a bounded local task to the installed OpenClaw CLI. Use only when OpenClaw is enabled and the task benefits from its local backend. This tool runs embedded/local and never delivers messages externally.",
    parameters: openClawInputSchema,
    needsApproval: async (_runContext, input) => {
      const parsed = openClawInputSchema.parse(input);
      return classifyTaskRisk(parsed.task).level !== "allow";
    },
    execute: async (input) => {
      const parsed = openClawInputSchema.parse(input);
      const risk = classifyTaskRisk(parsed.task);
      if (risk.level === "blocked") {
        return {
          ok: false,
          blocked: true,
          reason: risk.reason
        };
      }

      const timeoutSeconds = parsed.timeoutSeconds ?? 120;
      try {
        const result = await execFileAsync(
          "openclaw",
          [
            "agent",
            "--local",
            "--json",
            "--message",
            parsed.task,
            "--timeout",
            String(timeoutSeconds)
          ],
          {
            cwd: workingDirectory,
            timeout: timeoutSeconds * 1000,
            maxBuffer: 1024 * 1024
          }
        );

        return {
          ok: true,
          stdout: trimOutput(result.stdout),
          stderr: trimOutput(result.stderr)
        };
      } catch (error) {
        const failure = error as {
          stdout?: string;
          stderr?: string;
          code?: number | null;
          signal?: string | null;
          message?: string;
        };
        return {
          ok: false,
          exitCode: failure.code ?? null,
          signal: failure.signal ?? null,
          stdout: trimOutput(failure.stdout ?? ""),
          stderr: trimOutput(failure.stderr ?? failure.message ?? String(error))
        };
      }
    }
  });
}
