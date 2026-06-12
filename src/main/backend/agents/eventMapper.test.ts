import { describe, expect, it } from "vitest";
import type { RunStreamEvent } from "@openai/agents";
import { streamEventToBackendEvent } from "./eventMapper";

describe("eventMapper", () => {
  it("maps computer tool calls into backend tool-started events", () => {
    const event = {
      type: "run_item_stream_event",
      name: "tool_called",
      item: {
        rawItem: {
          type: "computer_call",
          actions: [
            { type: "move", x: 20, y: 40 },
            { type: "click", x: 20, y: 40, button: "left" }
          ]
        }
      }
    } as unknown as RunStreamEvent;

    expect(streamEventToBackendEvent("task-1", event, "computer_specialist")).toMatchObject({
      taskId: "task-1",
      type: "tool_started",
      summary: "Executing a GUI batch: move -> click."
    });
  });

  it("maps computer screenshots into screenshot events", () => {
    const event = {
      type: "run_item_stream_event",
      name: "tool_output",
      item: {
        rawItem: {
          type: "computer_call_result",
          output: {
            data: "screenshot-data"
          }
        }
      }
    } as unknown as RunStreamEvent;

    expect(streamEventToBackendEvent("task-2", event)).toMatchObject({
      taskId: "task-2",
      type: "screenshot",
      imageBase64: "screenshot-data"
    });
  });
});
