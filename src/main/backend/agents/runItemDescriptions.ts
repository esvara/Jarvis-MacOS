import type {
  AdaptedComputerAction,
  AdaptedRunItem
} from "./rawRunItemAdapter";

function truncateInlineText(value: string, limit = 48): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  if (normalized.length <= limit) {
    return normalized;
  }
  return `${normalized.slice(0, Math.max(0, limit - 3)).trimEnd()}...`;
}

export function describeComputerAction(action: AdaptedComputerAction): {
  summary: string;
  detail?: string;
} {
  switch (action.type) {
    case "click":
      return { summary: "Clicking on the interface." };
    case "double_click":
      return { summary: "Double-clicking on the interface." };
    case "type": {
      const text = truncateInlineText(action.text);
      return {
        summary: text ? `Typing "${text}".` : "Typing into the focused field.",
        detail: action.text || undefined
      };
    }
    case "keypress":
      return {
        summary: action.keys.length
          ? `Pressing ${action.keys.join(" + ")}.`
          : "Pressing a keyboard shortcut."
      };
    case "scroll":
      return { summary: "Scrolling the current view." };
    case "move":
      return { summary: "Moving the pointer." };
    case "drag":
      return { summary: "Dragging on screen." };
    case "wait":
      return { summary: "Waiting for the interface to settle." };
    case "screenshot":
      return { summary: "Checking the screen." };
  }
}

export function summarizeComputerActions(actions: AdaptedComputerAction[]): string {
  const types = actions.map((action) => action.type);
  if (types.length === 0) {
    return "Taking action on screen.";
  }
  if (types.length === 1) {
    return describeComputerAction(actions[0]).summary;
  }
  return `Executing a GUI batch: ${types.join(" -> ")}.`;
}

export function describeToolCall(
  item: AdaptedRunItem,
  specialistName?: string
): { summary: string; detail?: string } {
  switch (item.type) {
    case "computer_call":
      if (item.actions.length > 1) {
        return {
          summary: summarizeComputerActions(item.actions),
          detail: JSON.stringify(item.actions)
        };
      }
      if (item.actions[0]) {
        return describeComputerAction(item.actions[0]);
      }
      return { summary: "Taking action on screen." };
    case "shell_call":
      return {
        summary: `Running shell commands via ${specialistName ?? "workbench"}.`,
        detail: item.commands.join("\n")
      };
    case "apply_patch_call":
      return {
        summary: `Editing files via ${specialistName ?? "workbench"}.`,
        detail: item.path
      };
    case "computer_call_result":
      return {
        summary: "Computer returned a new screenshot."
      };
    case "unknown":
      return {
        summary: `Calling ${item.name ?? item.rawType ?? "a tool"}.`
      };
  }
}
