import { describe, expect, it } from "vitest";
import type { RunToolApprovalItem } from "@openai/agents";
import { formatApprovalRequest } from "./approvalFormatter";

function createApproval(rawItem: unknown): RunToolApprovalItem {
  return {
    rawItem,
    name: "computer",
    toolName: "computer",
    arguments: "{\"example\":true}"
  } as RunToolApprovalItem;
}

describe("approvalFormatter", () => {
  it("summarizes normalized computer actions", () => {
    const approval = formatApprovalRequest(
      createApproval({
        type: "computer_call",
        action: {
          type: "scroll",
          x: 10,
          y: 20,
          scroll_x: 5,
          scroll_y: -15
        }
      })
    );

    expect(approval).toEqual({
      kind: "computer",
      toolName: "computer",
      summary: "Computer wants to scroll by (5, -15)."
    });
  });

  it("shows the batch size for multi-action computer approvals", () => {
    const approval = formatApprovalRequest(
      createApproval({
        type: "computer_call",
        actions: [
          { type: "click", x: 1, y: 2, button: "left" },
          { type: "wait", ms: 300 }
        ]
      })
    );

    expect(approval.kind).toBe("computer");
    expect(approval.summary).toBe("Computer wants to execute 2 GUI actions.");
    expect(approval.detail).toContain("\"type\":\"click\"");
    expect(approval.detail).toContain("\"type\":\"wait\"");
  });
});
