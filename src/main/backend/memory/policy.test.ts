import { describe, expect, it } from "vitest";
import { evaluateMemoryWrite } from "./policy";

describe("evaluateMemoryWrite", () => {
  it("allows stable preferences", () => {
    const result = evaluateMemoryWrite({
      kind: "preference",
      subject: "Preferred browser",
      content: "Use Arc for link handling.",
      confidence: 0.91,
      source: "voice"
    });

    expect(result.decision).toBe("allow");
  });

  it("requires approval for volatile memories", () => {
    const result = evaluateMemoryWrite({
      kind: "workflow_default",
      subject: "Today plan",
      content: "Use Notes for today only.",
      confidence: 0.82,
      source: "voice"
    });

    expect(result.decision).toBe("approval_required");
  });

  it("blocks secret-like content", () => {
    const result = evaluateMemoryWrite({
      kind: "environment_fact",
      subject: "API token",
      content: "Remember the API token sk-secret",
      confidence: 0.95,
      source: "voice"
    });

    expect(result.decision).toBe("block");
  });
});
