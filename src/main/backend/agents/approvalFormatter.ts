import type { RunToolApprovalItem } from "@openai/agents";
import { adaptRawRunItem } from "./rawRunItemAdapter";

export interface ApprovalDescription {
  summary: string;
  detail?: string;
  kind: "computer" | "shell" | "apply_patch" | "function" | "memory";
  toolName: string;
}

export function formatApprovalRequest(interruption: RunToolApprovalItem): ApprovalDescription {
  const item = adaptRawRunItem(interruption.rawItem);
  const toolName = interruption.name ?? interruption.toolName ?? "tool";

  switch (item.type) {
    case "computer_call": {
      const [action] = item.actions;
      if (item.actions.length === 0) {
        return { kind: "computer", toolName, summary: "Computer wants to perform an action." };
      }
      if (item.actions.length > 1) {
        return {
          kind: "computer",
          toolName,
          summary: `Computer wants to execute ${item.actions.length} GUI actions.`,
          detail: JSON.stringify(item.actions)
        };
      }

      switch (action.type) {
        case "click":
          return {
            kind: "computer",
            toolName,
            summary: `Computer wants to click at (${action.x}, ${action.y}).`
          };
        case "double_click":
          return {
            kind: "computer",
            toolName,
            summary: `Computer wants to double-click at (${action.x}, ${action.y}).`
          };
        case "type":
          return {
            kind: "computer",
            toolName,
            summary: "Computer wants to type text into the focused surface.",
            detail: action.text
          };
        case "keypress":
          return {
            kind: "computer",
            toolName,
            summary: action.keys.length
              ? `Computer wants to press keys: ${action.keys.join(" + ")}.`
              : "Computer wants to press a keyboard shortcut."
          };
        case "scroll":
          return {
            kind: "computer",
            toolName,
            summary: `Computer wants to scroll by (${action.scrollX}, ${action.scrollY}).`
          };
        case "move":
          return {
            kind: "computer",
            toolName,
            summary: `Computer wants to move the pointer to (${action.x}, ${action.y}).`
          };
        case "drag":
          return {
            kind: "computer",
            toolName,
            summary: "Computer wants to perform a drag gesture."
          };
        case "wait":
          return {
            kind: "computer",
            toolName,
            summary: `Computer wants to wait for ${action.durationMs} ms.`
          };
        case "screenshot":
          return {
            kind: "computer",
            toolName,
            summary: "Computer wants to capture a fresh screenshot."
          };
      }
    }
    case "shell_call":
      return {
        kind: "shell",
        toolName,
        summary: "Workbench wants to run shell commands.",
        detail: item.commands.join("\n")
      };
    case "apply_patch_call":
      return {
        kind: "apply_patch",
        toolName,
        summary: `Workbench wants to ${item.operationType.replaceAll("_", " ")}.`,
        detail:
          item.operationType === "delete_file"
            ? item.path
            : [item.path, item.diff].filter(Boolean).join("\n")
      };
    case "computer_call_result":
      return {
        kind: "computer",
        toolName,
        summary: "Computer returned a screenshot."
      };
    case "unknown":
      return {
        kind: toolName.includes("memory") ? "memory" : "function",
        toolName,
        summary: `Agent wants to run ${toolName}.`,
        detail: interruption.arguments
      };
  }
}
