import type { RunStreamEvent } from "@openai/agents";
import type { BackendTaskEvent } from "../../../shared/types";
import { adaptRawRunItem } from "./rawRunItemAdapter";
import { describeToolCall } from "./runItemDescriptions";

export function streamEventToBackendEvent(
  taskId: string,
  event: RunStreamEvent,
  specialistName?: string
): BackendTaskEvent | undefined {
  const createdAt = new Date().toISOString();

  if (event.type === "agent_updated_stream_event") {
    return {
      taskId,
      type: "delegated",
      createdAt,
      summary: `Switched active agent to ${event.agent.name}.`
    };
  }

  if (event.type !== "run_item_stream_event") {
    return undefined;
  }

  const rawItem = event.item.rawItem;
  if (!rawItem) {
    return undefined;
  }

  const adapted = adaptRawRunItem(rawItem);

  if (event.name === "tool_called") {
    const described = describeToolCall(adapted, specialistName);
    return {
      taskId,
      type: "tool_started",
      createdAt,
      summary: described.summary,
      detail: described.detail,
      payload: adapted.raw
    };
  }

  if (event.name === "tool_output") {
    if (adapted.type === "computer_call_result") {
      return {
        taskId,
        type: "screenshot",
        createdAt,
        imageBase64: adapted.imageBase64
      };
    }

    return {
      taskId,
      type: "tool_finished",
      createdAt,
      summary: `Tool completed: ${adapted.type === "unknown" ? adapted.rawType ?? "unknown" : adapted.type}.`,
      payload: adapted.raw
    };
  }

  if (event.name === "handoff_occurred") {
    return {
      taskId,
      type: "delegated",
      createdAt,
      summary: `Handoff occurred inside ${specialistName ?? "run"}.`
    };
  }

  return undefined;
}
